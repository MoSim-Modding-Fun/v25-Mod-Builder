// MODBUILDER-SCRIPT-VERSION: 4
//
// This file is INSTALLED AND MAINTAINED BY v25 Mod Builder. It is copied into
// <UnityProject>/Assets/Editor/ automatically, and overwritten whenever the app ships a
// newer MODBUILDER-SCRIPT-VERSION. Don't hand-edit it inside a Unity project - edit
// unity/AddressablesModExporter.cs in the v25-Mod-Builder repo instead.
//
// It exists so the app is self-contained: a user who has only cloned the public template
// (github.com/MoSimulator/MoSimulator-Public) gets the command-line entry points below
// without having to install any script separately.
//
// Deliberately depends on nothing but UnityEditor + Addressables. Project types like
// RobotMetadataSO / BaseModpackSO are matched by base-type NAME via reflection rather
// than referenced directly, so this still compiles in projects whose assembly definition
// layout or namespaces differ from the template's.

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEditor.AddressableAssets;
using UnityEditor.AddressableAssets.Build;
using UnityEditor.AddressableAssets.Settings;
using UnityEditor.AddressableAssets.Settings.GroupSchemas;
using UnityEngine;

namespace Editor
{
    // Builds one or more addressable mod groups for the active build target, then
    // exports the platform catalog files + the group's robot DLLs into Mods/<GroupName>/.
    public class AddressablesModExporter : EditorWindow
    {
        const string RobotsRoot = "Assets/Prefabs/Reefscape/Robots/Mods";
        const string ModsOutputRoot = "Mods";

        // Must match RobotLoader.ModpackMetadataLabel - this is how the game discovers a
        // mod's BaseModpackSO (and through it, the mod's robots) at runtime.
        const string ModpackMetadataLabel = "modpack_metadata";

        // Base-type names we duck-type against (see file header for why this isn't a
        // direct type reference).
        const string RobotMetadataTypeName = "RobotMetadataSO";
        const string ModpackTypeName = "BaseModpackSO";

        public class ModBuildSpec
        {
            public string GroupName;
            public string Version;
            public string ZipName;
        }

        Vector2 _scroll;
        readonly HashSet<string> _selected = new HashSet<string>();
        readonly Dictionary<string, string> _versionByGroup = new Dictionary<string, string>();
        readonly Dictionary<string, string> _zipNameByGroup = new Dictionary<string, string>();

        [MenuItem("Tools/Addressables/Build And Export Mods")]
        static void Open() => GetWindow<AddressablesModExporter>("Build & Export Mods");

        void OnGUI()
        {
            var settings = AddressableAssetSettingsDefaultObject.Settings;
            if (settings == null)
            {
                EditorGUILayout.HelpBox("No Addressables settings found.", MessageType.Error);
                return;
            }

            EditorGUILayout.LabelField("Select mod groups to build:", EditorStyles.boldLabel);
            _scroll = EditorGUILayout.BeginScrollView(_scroll);
            foreach (var group in settings.groups)
            {
                if (group == null || group.ReadOnly) continue;
                if (SafeGetBundledSchema(group) == null) continue;

                var name = group.Name;
                bool was = _selected.Contains(name);
                bool now = EditorGUILayout.ToggleLeft(name, was);
                if (now && !was) _selected.Add(name);
                if (!now && was) _selected.Remove(name);

                if (now)
                {
                    EditorGUI.indentLevel++;
                    _versionByGroup.TryGetValue(name, out var version);
                    _versionByGroup[name] = EditorGUILayout.TextField("Version (optional)", version ?? "");

                    _zipNameByGroup.TryGetValue(name, out var zipName);
                    _zipNameByGroup[name] = EditorGUILayout.TextField("Zip name override (optional)", zipName ?? "");
                    EditorGUI.indentLevel--;
                }
            }
            EditorGUILayout.EndScrollView();

            EditorGUILayout.Space();
            EditorGUILayout.LabelField($"Active build target: {EditorUserBuildSettings.activeBuildTarget}");

            using (new EditorGUI.DisabledScope(_selected.Count == 0))
            {
                if (GUILayout.Button("Build Selected"))
                {
                    var specs = _selected.Select(name => new ModBuildSpec
                    {
                        GroupName = name,
                        Version = _versionByGroup.TryGetValue(name, out var v) ? v : null,
                        ZipName = _zipNameByGroup.TryGetValue(name, out var z) && !string.IsNullOrWhiteSpace(z) ? z : null
                    }).ToList();
                    BuildAndExport(specs);
                }
            }
        }

        // ---------------------------------------------------------------- auto-register

        // Command-line entry point:
        //   -executeMethod Editor.AddressablesModExporter.AutoRegisterModGroupsFromCommandLine
        // Turns any mod folder under RobotsRoot that isn't already backed by an
        // addressable group into one, so a freshly-added mod shows up as buildable
        // without the user hand-configuring Addressables first.
        public static void AutoRegisterModGroupsFromCommandLine()
        {
            int exitCode = 0;
            try
            {
                AutoRegisterModGroups();
            }
            catch (Exception e)
            {
                Debug.LogError($"AutoRegisterModGroups failed: {e}");
                exitCode = 1;
            }
            EditorApplication.Exit(exitCode);
        }

        [MenuItem("Tools/Addressables/Auto-Register New Mod Groups")]
        static void AutoRegisterMenuItem() => AutoRegisterModGroups();

        // Returns how many new groups were created.
        public static int AutoRegisterModGroups()
        {
            var settings = AddressableAssetSettingsDefaultObject.Settings;
            if (settings == null)
            {
                Debug.LogError("AutoRegisterModGroups: no Addressables settings found.");
                return 0;
            }

            var robotsRootAbs = Path.Combine(Application.dataPath, "..", RobotsRoot);
            if (!Directory.Exists(robotsRootAbs))
            {
                Debug.Log($"AutoRegisterModGroups: no mods root at {RobotsRoot}, nothing to do.");
                return 0;
            }

            // Match by GUID, not by name: a group whose name drifted from its folder name
            // is still a registration of that folder, and must not be duplicated.
            var registeredGuids = new HashSet<string>();
            foreach (var group in settings.groups)
            {
                if (group == null) continue;
                try
                {
                    foreach (var entry in group.entries)
                    {
                        if (entry != null && !string.IsNullOrEmpty(entry.guid)) registeredGuids.Add(entry.guid);
                    }
                }
                catch (Exception)
                {
                    // Same broken-group case SafeGetBundledSchema documents.
                    Debug.LogWarning($"Skipping unreadable addressable group '{group.name}' while collecting registered folders.");
                }
            }

            int created = 0;
            foreach (var dir in Directory.GetDirectories(robotsRootAbs))
            {
                var folderName = Path.GetFileName(dir);
                var folderAssetPath = RobotsRoot + "/" + folderName;
                var folderGuid = AssetDatabase.AssetPathToGUID(folderAssetPath);

                if (string.IsNullOrEmpty(folderGuid))
                {
                    Debug.LogWarning($"AutoRegisterModGroups: '{folderName}' has no asset GUID (not imported?), skipping.");
                    continue;
                }
                if (registeredGuids.Contains(folderGuid)) continue;

                if (!FolderHasSpawnableRobot(folderAssetPath))
                {
                    Debug.Log($"AutoRegisterModGroups: skipping '{folderName}' - no robot metadata with both RobotPrefab and MainMenuPrefab set.");
                    continue;
                }

                RegisterModGroup(settings, folderName, folderGuid);
                created++;
                Debug.Log($"AutoRegisterModGroups: registered new mod group '{folderName}'.");
            }

            if (created > 0)
            {
                AssetDatabase.SaveAssets();
                AssetDatabase.Refresh();
            }

            Debug.Log($"AutoRegisterModGroups: complete, {created} new group(s) registered.");
            return created;
        }

        // Makes sure `groupName` is a real addressable group, registering the matching mod
        // folder on the spot if it isn't one yet. Returns false (with a logged reason) if
        // there's nothing sensible to build under that name.
        static bool EnsureModGroupRegistered(AddressableAssetSettings settings, string groupName)
        {
            if (settings.FindGroup(groupName) != null) return true;

            var folderAssetPath = RobotsRoot + "/" + groupName;
            var folderGuid = AssetDatabase.AssetPathToGUID(folderAssetPath);
            if (string.IsNullOrEmpty(folderGuid))
            {
                Debug.LogError($"No addressable group named '{groupName}', and no mod folder at '{folderAssetPath}' to register.");
                return false;
            }
            if (!FolderHasSpawnableRobot(folderAssetPath))
            {
                Debug.LogError($"Mod folder '{groupName}' has no robot metadata with both RobotPrefab and MainMenuPrefab set, so it can't be built.");
                return false;
            }

            RegisterModGroup(settings, groupName, folderGuid);
            AssetDatabase.SaveAssets();
            Debug.Log($"Registered mod group '{groupName}' on demand for this build.");
            return true;
        }

        static void RegisterModGroup(AddressableAssetSettings settings, string groupName, string folderGuid)
        {
            var group = settings.FindGroup(groupName) ?? CreateModGroup(settings, groupName);

            settings.AddLabel(ModpackMetadataLabel);
            var entry = settings.CreateOrMoveEntry(folderGuid, group, readOnly: false, postEvent: false);
            if (entry != null) entry.SetLabel(ModpackMetadataLabel, true, true, false);

            ApplyModGroupPathsAndNaming(settings, group);
        }

        static AddressableAssetGroup CreateModGroup(AddressableAssetSettings settings, string groupName)
        {
            // Prefer the project's own group template (the "Packaged Assets" template the
            // modding docs tell users to pick manually) so auto-created groups get exactly
            // the same schema defaults as hand-made ones.
            AddressableAssetGroupTemplate template = null;
            if (settings.GroupTemplateObjects != null)
            {
                foreach (var obj in settings.GroupTemplateObjects)
                {
                    template = obj as AddressableAssetGroupTemplate;
                    if (template != null) break;
                }
            }

            if (template != null)
            {
                return settings.CreateGroup(groupName, false, false, false, null, template.GetTypes());
            }
            return settings.CreateGroup(groupName, false, false, false, null,
                typeof(BundledAssetGroupSchema), typeof(ContentUpdateGroupSchema));
        }

        // A mod folder only becomes a group once it holds a robot that can actually load
        // and spawn - i.e. some RobotMetadataSO-derived asset with both RobotPrefab and
        // MainMenuPrefab assigned. Anything less would build into a mod the game can't use.
        static bool FolderHasSpawnableRobot(string folderAssetPath)
        {
            foreach (var guid in AssetDatabase.FindAssets("t:ScriptableObject", new[] { folderAssetPath }))
            {
                var path = AssetDatabase.GUIDToAssetPath(guid);
                var asset = AssetDatabase.LoadAssetAtPath<ScriptableObject>(path);
                if (asset == null || !DerivesFrom(asset.GetType(), RobotMetadataTypeName)) continue;

                if (GetUnityObjectMember(asset, "RobotPrefab") != null &&
                    GetUnityObjectMember(asset, "MainMenuPrefab") != null)
                {
                    return true;
                }
            }
            return false;
        }

        static bool DerivesFrom(Type type, string baseTypeName)
        {
            for (var t = type; t != null; t = t.BaseType)
            {
                if (t.Name == baseTypeName) return true;
            }
            return false;
        }

        // Reads a property (public API, e.g. RobotPrefab) or its backing serialized field
        // (e.g. robotPrefab), whichever the project actually exposes.
        static UnityEngine.Object GetUnityObjectMember(object instance, string propertyName)
        {
            var type = instance.GetType();
            const BindingFlags flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

            for (var t = type; t != null; t = t.BaseType)
            {
                var prop = t.GetProperty(propertyName, flags);
                if (prop != null && prop.CanRead) return prop.GetValue(instance) as UnityEngine.Object;

                var fieldName = char.ToLowerInvariant(propertyName[0]) + propertyName.Substring(1);
                var field = t.GetField(fieldName, flags) ?? t.GetField(propertyName, flags);
                if (field != null) return field.GetValue(instance) as UnityEngine.Object;
            }
            return null;
        }

        // ---------------------------------------------------------------------- building

        // Built-in-shaders/MonoScript bundle naming and the "shared bundle settings" group are
        // PROJECT-WIDE settings, not per-group - so each selected group gets its own, separate
        // BuildPlayerContent() call (only that group's IncludeInBuild is true) with its own naming
        // prefix. Building several groups in a single Addressables build would make them collide.
        public static bool BuildAndExport(List<ModBuildSpec> specs)
        {
            var settings = AddressableAssetSettingsDefaultObject.Settings;
            if (settings == null) { Debug.LogError("No Addressables settings found."); return false; }
            if (specs == null || specs.Count == 0) { Debug.LogError("No groups selected."); return false; }

            var originalIncludeInBuild = new Dictionary<AddressableAssetGroup, bool>();
            foreach (var group in settings.groups)
            {
                var schema = SafeGetBundledSchema(group);
                if (schema != null) originalIncludeInBuild[group] = schema.IncludeInBuild;
            }

            var originalBuiltInBundleNaming = settings.BuiltInBundleNaming;
            var originalBuiltInBundleCustomNaming = settings.BuiltInBundleCustomNaming;
            var originalMonoScriptBundleNaming = settings.MonoScriptBundleNaming;
            var originalMonoScriptBundleCustomNaming = settings.MonoScriptBundleCustomNaming;
            var originalSharedBundleSettings = settings.SharedBundleSettings;
            var originalSharedBundleSettingsCustomGroupIndex = settings.SharedBundleSettingsCustomGroupIndex;

            try
            {
                bool allOk = true;
                foreach (var spec in specs)
                {
                    // Registration happens here, at build time, rather than when the app
                    // first spots an unregistered mod folder: a folder the user never
                    // chooses to build should never get an addressable group created for it.
                    if (!EnsureModGroupRegistered(settings, spec.GroupName))
                    {
                        allOk = false;
                        continue;
                    }
                    if (!BuildOneGroup(settings, spec))
                    {
                        allOk = false;
                        continue;
                    }
                    ExportGroup(spec.GroupName, spec.ZipName ?? spec.GroupName, spec.Version);
                }

                if (allOk) Debug.Log("Build and export complete.");
                return allOk;
            }
            finally
            {
                foreach (var kv in originalIncludeInBuild)
                {
                    var schema = SafeGetBundledSchema(kv.Key);
                    if (schema != null) schema.IncludeInBuild = kv.Value;
                }

                settings.BuiltInBundleNaming = originalBuiltInBundleNaming;
                settings.BuiltInBundleCustomNaming = originalBuiltInBundleCustomNaming;
                settings.MonoScriptBundleNaming = originalMonoScriptBundleNaming;
                settings.MonoScriptBundleCustomNaming = originalMonoScriptBundleCustomNaming;
                settings.SharedBundleSettings = originalSharedBundleSettings;
                settings.SharedBundleSettingsCustomGroupIndex = originalSharedBundleSettingsCustomGroupIndex;
            }
        }

        // Build and load paths are NOT set by default on a group (and a group made by hand
        // via the Addressables window won't have them either), so they're (re)applied on
        // every build rather than assumed - a group whose LoadPath is wrong builds a catalog
        // the game can't resolve at runtime.
        static void ApplyModGroupPathsAndNaming(AddressableAssetSettings settings, AddressableAssetGroup group)
        {
            var schema = group.GetSchema<BundledAssetGroupSchema>() ?? group.AddSchema<BundledAssetGroupSchema>();

            var buildVariable = $"{group.Name}_BuildPath";
            var loadVariable = $"{group.Name}_LoadPath";
            var existing = settings.profileSettings.GetVariableNames();

            // SetVariableByName needs the NAME of a profile variable, not a raw path -
            // create it once (same convention as AddressableCustomPath.cs) then point at it.
            if (!existing.Contains(buildVariable))
            {
                settings.profileSettings.CreateValue(buildVariable,
                    "{UnityEngine.Application.dataPath}/../" + ModsOutputRoot + "/" + group.Name);
            }
            if (!existing.Contains(loadVariable))
            {
                settings.profileSettings.CreateValue(loadVariable,
                    "{UnityEngine.Application.persistentDataPath}/" + ModsOutputRoot + "/" + group.Name);
            }

            schema.BuildPath.SetVariableByName(settings, buildVariable);
            schema.LoadPath.SetVariableByName(settings, loadVariable);

            EditorUtility.SetDirty(schema);
            EditorUtility.SetDirty(group);
        }

        // A group whose .asset was deleted outside Unity still shows up in
        // settings.groups as a non-null but broken object, and GetSchema throws a
        // NullReferenceException on it - which would otherwise abort every build in the
        // project, not just that one group. Treat it as "no schema" and move on.
        static BundledAssetGroupSchema SafeGetBundledSchema(AddressableAssetGroup group)
        {
            if (group == null) return null;
            try
            {
                return group.GetSchema<BundledAssetGroupSchema>();
            }
            catch (Exception)
            {
                Debug.LogWarning($"Skipping unreadable addressable group '{group.name}' (its asset may have been deleted outside Unity).");
                return null;
            }
        }

        static bool BuildOneGroup(AddressableAssetSettings settings, ModBuildSpec spec)
        {
            int groupIndex = -1;
            for (int i = 0; i < settings.groups.Count; i++)
            {
                var group = settings.groups[i];
                if (group == null) continue;
                var schema = SafeGetBundledSchema(group);
                if (schema == null) continue;

                bool selected = group.Name == spec.GroupName;
                schema.IncludeInBuild = selected;
                if (selected) groupIndex = i;
            }

            if (groupIndex < 0)
            {
                Debug.LogError($"No addressable group named '{spec.GroupName}' with a BundledAssetGroupSchema.");
                return false;
            }

            var group2 = settings.groups[groupIndex];
            var buildPath = Path.Combine(Application.dataPath, "..", ModsOutputRoot, group2.Name);
            Directory.CreateDirectory(buildPath);

            ApplyModGroupPathsAndNaming(settings, group2);

            // Prefix the shared built-in-shaders/MonoScript bundles with this group's name so
            // different mods' bundles don't collide (matches the "chinamodpack" style prefix
            // already configured manually in AddressableAssetSettings.asset).
            var prefix = Regex.Replace(group2.Name, "[^a-zA-Z0-9]", "").ToLowerInvariant();
            settings.BuiltInBundleNaming = BuiltInBundleNaming.Custom;
            settings.BuiltInBundleCustomNaming = prefix;
            settings.MonoScriptBundleNaming = MonoScriptBundleNaming.Custom;
            settings.MonoScriptBundleCustomNaming = prefix;
            settings.SharedBundleSettings = SharedBundleSettings.CustomGroup;
            settings.SharedBundleSettingsCustomGroupIndex = groupIndex;

            Debug.Log($"Building addressables for: {spec.GroupName} (target: {EditorUserBuildSettings.activeBuildTarget}, prefix: {prefix})");
            AddressableAssetSettings.BuildPlayerContent(out AddressablesPlayerBuildResult result);

            if (!string.IsNullOrEmpty(result.Error))
            {
                Debug.LogError($"Addressables build failed for '{spec.GroupName}': {result.Error}");
                return false;
            }
            return true;
        }

        static void ExportGroup(string groupName, string zipName, string version)
        {
            var modsRoot = Path.Combine(Application.dataPath, "..", ModsOutputRoot);
            var modFolder = Path.Combine(modsRoot, groupName);
            Directory.CreateDirectory(modFolder);

            var target = EditorUserBuildSettings.activeBuildTarget;
            var osFolder = OsFolderForTarget(target);
            var aaFolder = Path.Combine(Application.dataPath, "..", "Library", "com.unity.addressables", "aa", osFolder);
            foreach (var fileName in new[] { "catalog.json", "catalog.hash", "settings.json" })
            {
                var src = Path.Combine(aaFolder, fileName);
                if (!File.Exists(src)) { Debug.LogWarning($"[{groupName}] missing {src}"); continue; }
                File.Copy(src, Path.Combine(modFolder, fileName), overwrite: true);
            }

            // Every robot in this group has its own asmdef under RobotsRoot/<GroupName>/<Team>/;
            // the asmdef's "name" field is the DLL Unity emits into Library/ScriptAssemblies/.
            var robotFolder = Path.Combine(Application.dataPath, "..", RobotsRoot, groupName);
            if (Directory.Exists(robotFolder))
            {
                var scriptAssemblies = Path.Combine(Application.dataPath, "..", "Library", "ScriptAssemblies");
                foreach (var asmdefPath in Directory.GetFiles(robotFolder, "*.asmdef", SearchOption.AllDirectories))
                {
                    var asmName = ExtractAsmdefName(asmdefPath);
                    if (string.IsNullOrEmpty(asmName)) continue;

                    var dllSrc = Path.Combine(scriptAssemblies, asmName + ".dll");
                    if (!File.Exists(dllSrc)) { Debug.LogWarning($"[{groupName}] missing dll {dllSrc}"); continue; }
                    File.Copy(dllSrc, Path.Combine(modFolder, asmName + ".dll"), overwrite: true);
                }
            }
            else
            {
                Debug.LogWarning($"[{groupName}] no robot folder at {robotFolder}, skipping DLL export");
            }

            ZipAndCleanup(modFolder, modsRoot, zipName, ZipPlatformLabel(target), version);
        }

        static void ZipAndCleanup(string modFolder, string modsRoot, string zipName, string platformLabel, string version)
        {
            var archiveName = string.IsNullOrWhiteSpace(version)
                ? $"{zipName} {platformLabel}.zip"
                : $"{zipName} {version} {platformLabel}.zip";
            var zipPath = Path.Combine(modsRoot, archiveName);

            // zipName only brands the ARCHIVE FILE's name. The folder *inside* the zip must
            // stay modFolder's real name (the addressable group name) unchanged: each group's
            // LoadPath profile variable is baked into the catalog as ".../Mods/<groupName>/...",
            // so if the internal folder doesn't match the group name after extraction, the game
            // 404s trying to load the bundle from the (correct) group-name path that no longer
            // exists on disk. Renaming it to a branded zipName here broke exactly that.
            var sourceFolder = Path.GetFullPath(modFolder);

            if (File.Exists(zipPath)) File.Delete(zipPath);
            ZipFile.CreateFromDirectory(sourceFolder, zipPath, System.IO.Compression.CompressionLevel.Optimal, includeBaseDirectory: true);
            Directory.Delete(sourceFolder, recursive: true);

            Debug.Log($"Zipped mod folder to {zipPath}");
        }

        static string ExtractAsmdefName(string path)
        {
            var json = File.ReadAllText(path);
            var match = Regex.Match(json, "\"name\"\\s*:\\s*\"([^\"]+)\"");
            return match.Success ? match.Groups[1].Value : null;
        }

        static string OsFolderForTarget(BuildTarget target)
        {
            switch (target)
            {
                case BuildTarget.StandaloneWindows:
                case BuildTarget.StandaloneWindows64:
                    return "Windows";
                case BuildTarget.StandaloneOSX:
                    return "OSX";
                case BuildTarget.StandaloneLinux64:
                    return "Linux";
                default:
                    throw new NotSupportedException($"Unsupported build target: {target}");
            }
        }

        static string ZipPlatformLabel(BuildTarget target)
        {
            switch (target)
            {
                case BuildTarget.StandaloneWindows:
                case BuildTarget.StandaloneWindows64:
                    return "Windows";
                case BuildTarget.StandaloneOSX:
                    return "MacOS";
                case BuildTarget.StandaloneLinux64:
                    return "Linux";
                default:
                    throw new NotSupportedException($"Unsupported build target: {target}");
            }
        }

        // Command-line entry point:
        //   -executeMethod Editor.AddressablesModExporter.BuildFromCommandLine
        //   -groups "Name1|Name2"  [-versions "v2.1.0|v1.0.0"]  [-zipNames "Zip One|Zip Two"]
        // -versions and -zipNames, if given, must have the same number of |-separated
        // entries as -groups, matched by position. Use an empty entry ("Name1||Name3")
        // to skip a value for one group.
        public static void BuildFromCommandLine()
        {
            var args = Environment.GetCommandLineArgs();
            string GetArg(string name)
            {
                for (int i = 0; i < args.Length - 1; i++)
                    if (args[i] == name) return args[i + 1];
                return null;
            }

            var groupsArg = GetArg("-groups");
            if (string.IsNullOrEmpty(groupsArg))
            {
                Debug.LogError("BuildFromCommandLine: missing -groups \"Name1|Name2\" argument.");
                EditorApplication.Exit(1);
                return;
            }

            var groupNames = groupsArg.Split('|').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
            var versions = GetArg("-versions")?.Split('|');
            var zipNames = GetArg("-zipNames")?.Split('|');

            var specs = groupNames.Select((name, i) => new ModBuildSpec
            {
                GroupName = name,
                Version = versions != null && i < versions.Length && versions[i].Length > 0 ? versions[i] : null,
                ZipName = zipNames != null && i < zipNames.Length && zipNames[i].Length > 0 ? zipNames[i] : null
            }).ToList();

            bool ok = BuildAndExport(specs);
            EditorApplication.Exit(ok ? 0 : 1);
        }
    }
}
