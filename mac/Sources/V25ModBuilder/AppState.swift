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

    @Published var unityPath: String?
    @Published var detectedUnityPath: String?

    @Published var outputDir: String?

    @Published var selectedPlatforms: Set<PlatformTarget> = [.win64, .osx, .linux64]

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
            applyProject(ProjectService.resolveProject(at: path))
        }
    }

    func selectProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyProject(ProjectService.resolveProject(at: url.path))
    }

    private func applyProject(_ info: ProjectInfo) {
        projectPath = info.projectPath
        unityVersion = info.unityVersion
        projectError = info.error

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
