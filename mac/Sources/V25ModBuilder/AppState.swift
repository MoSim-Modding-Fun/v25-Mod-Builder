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
    @Published var isScanningForNewGroups = false

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
        canBuild && !isScanningForNewGroups && (!releaseEnabled || !releaseTag.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // Remembers, per project (this app session only - not persisted), the exact set of
    // candidate mod folders the last scan already tried. Mirrors main.js's
    // scannedCandidatesByProject: a folder whose robot is missing RobotPrefab/
    // MainMenuPrefab never turns into a group no matter how many times Unity re-scans
    // it, so without this a project with one such folder would re-run the full (slow -
    // genuine Unity domain-reload wall-clock time) scan on every single load.
    private var scannedCandidatesByProject: [String: String] = [:]

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

    /// Populates the UI immediately from the fast, filesystem-only read, then - only if
    /// needed - runs the slower Unity auto-register scan in the background and merges
    /// in any newly-discovered groups when it finishes. Mirrors main.js's
    /// loadProject()/scanForNewGroupsInBackground() split, so a slow scan (launching
    /// Unity headless) never blocks the initial "project selected" feedback.
    private func loadProject(at rawPath: String) {
        let info = ProjectService.resolveProjectFast(at: rawPath)
        applyProject(info)

        guard info.error == nil, info.scanning else { return }
        // Use info.projectPath (normalized by resolveProjectFast), not rawPath - they
        // can differ by a trailing slash, which would make the `self.projectPath ==
        // path` check below always fail and silently drop every scan result.
        let path = info.projectPath
        let scanUnityPath = unityPath
        Task {
            let refreshedGroups = await ProjectService.scanForNewGroups(projectPath: path, unityPath: scanUnityPath)
            // The user may have loaded a different project while this scan was running -
            // only apply the result if it's still the one on screen.
            guard self.projectPath == path else { return }
            self.isScanningForNewGroups = false
            let existingNames = Set(self.groups.map(\.name))
            guard Set(refreshedGroups) != existingNames else { return }
            self.groups = refreshedGroups.map { ModGroup(name: $0) }
        }
    }

    private func applyProject(_ info: ProjectInfo) {
        projectPath = info.projectPath
        unityVersion = info.unityVersion
        projectError = info.error
        isScanningForNewGroups = info.scanning

        if info.error == nil {
            defaults.set(info.projectPath, forKey: Keys.projectPath)
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
            groups = []
        }
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
