import SwiftUI
import AppKit
import Combine

/// Holds all cross-page UI state and settings persistence (via UserDefaults instead
/// of a hand-rolled settings.json - more idiomatic for a native app, same three
/// remembered values as the Electron app: project path, Unity path override, output
/// dir override).
@MainActor
final class AppState: ObservableObject {
    @Published var projectPath: String?
    @Published var unityVersion: String?
    @Published var projectError: String?
    @Published var groups: [ModGroup] = []

    // Backing state for the DETECT NEW MODS button - mirrors renderer.js's
    // registeredGroupNames/unregisteredModFolders globals. `groups` (above) is the
    // merged, sorted, buildable list shown in the UI; these two track the raw pieces so
    // a re-detect or a toggle can recompute that merge without re-reading the project.
    @Published var registeredGroupNames: [String] = []
    @Published var unregisteredModFolders: [String] = []
    @Published var detectStatus: String = ""

    @Published var unityPath: String?
    @Published var detectedUnityPath: String?

    @Published var outputDir: String?

    @Published var selectedPlatforms: Set<PlatformTarget> = [.win64, .osx, .linux64]

    @Published var releaseEnabled = false
    @Published var releaseTag = ""
    @Published var releaseTitle = ""
    @Published var releaseNotes = ""

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let projectPath = "projectPath"
        static let unityPathOverride = "unityPathOverride"
        static let outputDirOverride = "outputDirOverride"
    }

    var isUnityPathDetected: Bool { unityPath != nil && unityPath == detectedUnityPath }

    var canBuild: Bool {
        projectPath != nil && unityPath != nil && groups.contains(where: { $0.checked }) && !selectedPlatforms.isEmpty
    }

    var canStartBuild: Bool {
        canBuild && (!releaseEnabled || !releaseTag.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Called once on launch - restores the remembered project/paths, same as the
    /// Electron app's startup `loadSettings().then(...)` block.
    func restoreLastProject() {
        guard projectPath == nil else { return } // avoid re-running on every view re-appear

        if let override = defaults.string(forKey: Keys.unityPathOverride) {
            unityPath = override
        }
        if let dir = defaults.string(forKey: Keys.outputDirOverride) {
            outputDir = dir
        }
        if let path = defaults.string(forKey: Keys.projectPath) {
            loadProject(at: path)
        }
    }

    func selectProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadProject(at: url.path)
    }

    /// Pure filesystem read, same as main.js's loadProject() - nothing here launches
    /// Unity, so selecting a project is instant. There is no background scan to kick off
    /// anymore: a mod folder without a group just sits there until the user explicitly
    /// hits DETECT NEW MODS (see detectNewMods() below) and then builds it.
    private func loadProject(at rawPath: String) {
        let info = ProjectService.resolveProjectFast(at: rawPath)
        applyProject(info)
    }

    private func applyProject(_ info: ProjectInfo) {
        projectPath = info.projectPath
        unityVersion = info.unityVersion
        projectError = info.error

        // A detect result from a previously-loaded project says nothing about this one -
        // mirrors applyProjectInfo() in renderer.js clearing unregisteredModFolders/
        // detectStatus on every project (re)load.
        unregisteredModFolders = []
        detectStatus = ""

        if info.error == nil {
            defaults.set(info.projectPath, forKey: Keys.projectPath)
            registeredGroupNames = info.groups
            groups = info.groups.map { ModGroup(name: $0) }

            if let version = info.unityVersion {
                let detected = UnityLocator.detect(version: version)
                detectedUnityPath = detected
                // A manually-set override (already restored, if any) always wins over
                // auto-detection, matching the Electron app's priority order.
                if unityPath == nil {
                    unityPath = detected
                }
            }
        } else {
            registeredGroupNames = []
            groups = []
        }
    }

    /// Lists mod folders that exist on disk but have no addressable group yet - a pure
    /// filesystem read, so this is instant and (crucially) does not launch Unity and does
    /// not create anything. Mirrors renderer.js's detect-mods-btn click handler. A folder
    /// only becomes a real group if the user checks it here and then builds it (see
    /// EnsureModGroupRegistered in AddressablesModExporter.cs).
    func detectNewMods() {
        guard let projectPath else { return }

        let unregistered = ProjectService.detectUnregisteredModFolders(projectPath: projectPath)
        unregisteredModFolders = unregistered
        rebuildGroupsList()
        detectStatus = unregistered.isEmpty
            ? "No unregistered mod folders found."
            : "Found \(unregistered.count) new mod folder(s) - check one to build it."
    }

    /// Merges registered group names with DETECT-found unregistered folders into the
    /// single checkable list the Groups page shows, preserving any in-progress
    /// checked/version/zipName state for names that survive the merge. Mirrors
    /// renderer.js's renderGroups(): `[...new Set([...names, ...unregisteredNames])].sort()`.
    private func rebuildGroupsList() {
        let mergedNames = Array(Set(registeredGroupNames).union(unregisteredModFolders)).sorted()
        let existingByName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })
        groups = mergedNames.map { existingByName[$0] ?? ModGroup(name: $0) }
    }

    func browseUnityPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true // .app bundles are directories
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if FileManager.default.fileExists(atPath: "/Applications/Unity/Hub/Editor") {
            panel.directoryURL = URL(fileURLWithPath: "/Applications/Unity/Hub/Editor")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var chosen = url.path
        if chosen.hasSuffix(".app") {
            chosen = (chosen as NSString).appendingPathComponent("Contents/MacOS/Unity")
        }
        unityPath = chosen
        detectedUnityPath = nil
        defaults.set(chosen, forKey: Keys.unityPathOverride)
    }

    func browseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDir = url.path
        defaults.set(url.path, forKey: Keys.outputDirOverride)
    }

    func resetOutputDir() {
        outputDir = nil
        defaults.removeObject(forKey: Keys.outputDirOverride)
    }
}
