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
    ]

    static func resolveProject(at path: String) -> ProjectInfo {
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
