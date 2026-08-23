import Foundation

struct ProjectInfo {
    let projectPath: String
    let unityVersion: String?
    let groups: [String]
    let error: String?
    /// True if a background Unity auto-register scan was kicked off for this project -
    /// the caller should show a "scanning" indicator until scanForNewGroups resolves.
    let scanning: Bool
}

/// Mirrors main.js's listAddressableGroups()/resolveProject() in the Electron app -
/// same reserved-name exclusions, same ProjectVersion.txt parsing, same
/// AssetGroups .asset scanning, so behavior stays identical across both apps.
enum ProjectService {
    static let reservedGroupNames: Set<String> = [
        "Built In Data", "EditorSceneList", "Default Local Group", "LynkMod", "MechTechMod",
    ]

    /// Must match AddressablesModExporter.cs's RobotsRoot constant exactly.
    static let robotsRootRelativePath = "Assets/Prefabs/Reefscape/Robots/Mods"

    /// Mirrors main.js's resolveProjectFast(): filesystem-only, no Unity launch, so the
    /// UI can populate immediately instead of blocking on autoRegisterNewModFolders
    /// (which can take real wall-clock time). Call scanForNewGroups() afterwards
    /// (only if `scanning` is true) to run that scan in the background.
    static func resolveProjectFast(at rawPath: String) -> ProjectInfo {
        // A trailing slash would otherwise make the same project look like two
        // different keys to UnityLaunchQueue, letting a scan and a build race for the
        // same project's lock file.
        let path = (rawPath as NSString).standardizingPath
        let fm = FileManager.default
        let assetsDir = (path as NSString).appendingPathComponent("Assets")
        let versionFile = (path as NSString).appendingPathComponent("ProjectSettings/ProjectVersion.txt")

        guard fm.fileExists(atPath: assetsDir), fm.fileExists(atPath: versionFile) else {
            return ProjectInfo(
                projectPath: path, unityVersion: nil, groups: [],
                error: "\"\(path)\" doesn't look like a Unity project (no Assets/ or ProjectSettings/ProjectVersion.txt).",
                scanning: false
            )
        }

        guard let versionText = try? String(contentsOfFile: versionFile, encoding: .utf8) else {
            return ProjectInfo(projectPath: path, unityVersion: nil, groups: [], error: "Couldn't read ProjectVersion.txt.", scanning: false)
        }

        let unityVersion = extractEditorVersion(versionText)
        let groups = listAddressableGroups(projectPath: path)
        let needsScan = !findCandidateModFolders(projectPath: path, knownGroupNames: groups).isEmpty
        return ProjectInfo(projectPath: path, unityVersion: unityVersion, groups: groups, error: nil, scanning: needsScan)
    }

    /// Runs the (possibly slow) auto-register pass and returns the refreshed group
    /// list. Call only after resolveProjectFast() reported `scanning: true`.
    static func scanForNewGroups(projectPath: String, unityPath: String?) async -> [String] {
        await autoRegisterNewModFolders(projectPath: projectPath, unityPath: unityPath)
        return listAddressableGroups(projectPath: projectPath)
    }

    /// Runs Editor.AddressablesModExporter.AutoRegisterModGroupsFromCommandLine, which
    /// scans RobotsRoot for folders with a robot that can actually load and spawn
    /// (RobotPrefab + MainMenuPrefab both set) and turns any new ones into a proper
    /// Addressable mod group + modpack metadata asset. Best-effort: any failure here
    /// just means new folders won't show up as groups yet, not a fatal project-load error.
    private static func autoRegisterNewModFolders(projectPath: String, unityPath: String?) async {
        guard let unityPath, FileManager.default.isExecutableFile(atPath: unityPath) else { return }
        let candidates = findCandidateModFolders(projectPath: projectPath, knownGroupNames: listAddressableGroups(projectPath: projectPath))
        guard !candidates.isEmpty else { return }

        let args = [
            "-batchmode", "-quit", "-nographics",
            "-projectPath", projectPath,
            "-executeMethod", "Editor.AddressablesModExporter.AutoRegisterModGroupsFromCommandLine",
        ]
        await UnityLaunchQueue.shared.enqueue(projectPath: projectPath) {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: unityPath)
                process.arguments = args
                process.terminationHandler = { proc in continuation.resume(returning: proc.terminationStatus) }
                do { try process.run() } catch { continuation.resume(returning: -1) }
            }
        }
    }

    /// Cheap filesystem-only pre-check so a normal project select stays instant; Unity
    /// only gets launched (slow) when there's actually a subfolder not already used by
    /// some group's entry. Name-matching here is just an optimization, not the
    /// correctness check - AutoRegisterModGroups on the Unity side re-checks by folder
    /// GUID against every group's real entries, so a stale/mismatched group name can at
    /// worst trigger an unnecessary (harmless) Unity launch, never a duplicate group.
    private static func findCandidateModFolders(projectPath: String, knownGroupNames: [String]) -> [String] {
        let robotsRoot = (projectPath as NSString).appendingPathComponent(robotsRootRelativePath)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: robotsRoot, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let entries = try? fm.contentsOfDirectory(atPath: robotsRoot) else { return [] }

        let known = Set(knownGroupNames)
        return entries.filter { name in
            guard !known.contains(name) else { return false }
            var entryIsDir: ObjCBool = false
            let full = (robotsRoot as NSString).appendingPathComponent(name)
            return fm.fileExists(atPath: full, isDirectory: &entryIsDir) && entryIsDir.boolValue
        }
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
