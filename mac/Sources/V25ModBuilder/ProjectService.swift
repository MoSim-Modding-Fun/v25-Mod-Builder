import Foundation

struct ProjectInfo {
    let projectPath: String
    let unityVersion: String?
    let groups: [String]
    let error: String?
}

/// Mirrors main.js's listAddressableGroups()/resolveProject() in the Electron app -
/// same reserved-name exclusions, same ProjectVersion.txt parsing, same
/// AssetGroups .asset scanning, so behavior stays identical across both apps.
enum ProjectService {
    static let reservedGroupNames: Set<String> = [
        "Built In Data", "EditorSceneList", "Default Local Group", "LynkMod", "MechTechMod",
        // The example mod that ships in the public template project - auto-registration would
        // otherwise surface it as a buildable group for every single user.
        "LynkModOfficial",
    ]

    /// Must match AddressablesModExporter.cs's RobotsRoot constant exactly.
    static let robotsRootRelativePath = "Assets/Prefabs/Reefscape/Robots/Mods"

    /// Mirrors main.js's resolveProjectFast(): filesystem-only, no Unity launch anywhere
    /// in the project-loading path, so selecting a project is instant.
    static func resolveProjectFast(at rawPath: String) -> ProjectInfo {
        // A trailing slash would otherwise make the same project look like two
        // different keys to UnityLaunchQueue, letting a build-time launch race against
        // itself for the same project's lock file.
        let path = (rawPath as NSString).standardizingPath
        let fm = FileManager.default
        let assetsDir = (path as NSString).appendingPathComponent("Assets")
        let versionFile = (path as NSString).appendingPathComponent("ProjectSettings/ProjectVersion.txt")

        guard fm.fileExists(atPath: assetsDir), fm.fileExists(atPath: versionFile) else {
            return ProjectInfo(
                projectPath: path, unityVersion: nil, groups: [],
                error: "\"\(path)\" doesn't look like a Unity project (no Assets/ or ProjectSettings/ProjectVersion.txt)."
            )
        }

        guard let versionText = try? String(contentsOfFile: versionFile, encoding: .utf8) else {
            return ProjectInfo(projectPath: path, unityVersion: nil, groups: [], error: "Couldn't read ProjectVersion.txt.")
        }

        let unityVersion = extractEditorVersion(versionText)
        let groups = listAddressableGroups(projectPath: path)
        return ProjectInfo(projectPath: path, unityVersion: unityVersion, groups: groups, error: nil)
    }

    /// Mod folders that exist on disk but aren't in any addressable group yet. Purely a
    /// filesystem read - no Unity launch - so the DETECT button is instant. Nothing is
    /// created here: an unregistered folder only becomes a real addressable group if the
    /// user actually picks it and builds it (see EnsureModGroupRegistered in the exporter
    /// script). Mirrors main.js's 'detect-new-mods' IPC handler.
    static func detectUnregisteredModFolders(projectPath: String) -> [String] {
        findCandidateModFolders(projectPath: projectPath)
    }

    /// Cheap filesystem-only pre-check so a normal project select stays instant; a group
    /// only gets created (at build time, via EnsureModGroupRegistered on the Unity side)
    /// when there's actually a mod folder no group has claimed yet.
    ///
    /// Matches on GUID rather than on folder-vs-group name, exactly like
    /// AutoRegisterModGroups does on the Unity side. Name matching gets this wrong in both
    /// directions: a group whose name drifted from its folder (folder "Lanternfly"
    /// registered as group "Lanternfly Mod") looks unregistered forever, and so does any
    /// reserved group excluded from the UI list.
    private static func findCandidateModFolders(projectPath: String) -> [String] {
        let robotsRoot = (projectPath as NSString).appendingPathComponent(robotsRootRelativePath)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: robotsRoot, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let entries = try? fm.contentsOfDirectory(atPath: robotsRoot) else { return [] }

        let registered = listRegisteredEntryGuids(projectPath: projectPath)
        return entries.filter { name in
            var entryIsDir: ObjCBool = false
            let full = (robotsRoot as NSString).appendingPathComponent(name)
            guard fm.fileExists(atPath: full, isDirectory: &entryIsDir), entryIsDir.boolValue else { return false }
            // No .meta yet means Unity hasn't imported it - let the scan handle it.
            guard let guid = readAssetGuid(assetPath: full) else { return true }
            return !registered.contains(guid)
        }
    }

    /// Every asset GUID already claimed by some group's entry list. Entries are the
    /// "- m_GUID:" list items under m_SerializeEntries; the group's own bare "m_GUID:"
    /// line has no leading dash, so this deliberately doesn't pick it up.
    private static func listRegisteredEntryGuids(projectPath: String) -> Set<String> {
        let groupsDir = (projectPath as NSString).appendingPathComponent("Assets/AddressableAssetsData/AssetGroups")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: groupsDir) else { return [] }

        var guids = Set<String>()
        for entry in entries where entry.hasSuffix(".asset") {
            let fullPath = (groupsDir as NSString).appendingPathComponent(entry)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            for rawLine in content.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("- m_GUID:") else { continue }
                let value = line.dropFirst("- m_GUID:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { guids.insert(value) }
            }
        }
        return guids
    }

    /// Unity stores an asset's GUID in its sibling .meta file.
    private static func readAssetGuid(assetPath: String) -> String? {
        guard let meta = try? String(contentsOfFile: assetPath + ".meta", encoding: .utf8) else { return nil }
        for rawLine in meta.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("guid:") else { continue }
            let value = line.dropFirst("guid:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func extractEditorVersion(_ text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("m_EditorVersion:") else { continue }
            let value = line.dropFirst("m_EditorVersion:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func listAddressableGroups(projectPath: String) -> [String] {
        let groupsDir = (projectPath as NSString).appendingPathComponent("Assets/AddressableAssetsData/AssetGroups")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: groupsDir) else { return [] }

        var names: [String] = []
        for entry in entries where entry.hasSuffix(".asset") {
            let fullPath = (groupsDir as NSString).appendingPathComponent(entry)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            guard let range = content.range(of: "m_GroupName:") else { continue }
            let rest = content[range.upperBound...]
            let line = rest.prefix(while: { !$0.isNewline })
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !reservedGroupNames.contains(name) else { continue }
            names.append(name)
        }
        return names.sorted()
    }
}

/// Mirrors defaultUnityPaths()/detectUnity() in main.js for the darwin case.
enum UnityLocator {
    static func defaultPath(forVersion version: String) -> String {
        "/Applications/Unity/Hub/Editor/\(version)/Unity.app/Contents/MacOS/Unity"
    }

    static func detect(version: String) -> String? {
        let path = defaultPath(forVersion: version)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
