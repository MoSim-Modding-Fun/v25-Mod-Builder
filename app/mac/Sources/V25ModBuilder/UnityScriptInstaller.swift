import Foundation

/// Swift port of unity-script-installer.js - keep the two in sync.
///
/// The app talks to Unity exclusively through -executeMethod entry points in
/// Editor/AddressablesModExporter.cs, and the public template project
/// (github.com/MoSimulator/MoSimulator-Public) does not ship that script. So the app
/// carries its own copy and installs it into the target project on demand; requiring
/// users to add it by hand would mean the app doesn't work on a fresh clone.
enum UnityScriptInstaller {
    enum Status {
        case current
        case installed
        case updated
        case failed(String)
    }

    private static let exporterScriptRelativePath = "Assets/Editor/AddressablesModExporter.cs"

    /// Bumped whenever unity/AddressablesModExporter.cs changes, so an older copy already
    /// sitting in a project gets replaced instead of silently shadowing the new one.
    static func exporterScriptVersion(_ source: String) -> Int {
        guard let range = source.range(of: "MODBUILDER-SCRIPT-VERSION:") else { return 0 }
        let rest = source[range.upperBound...].prefix(while: { !$0.isNewline })
        return Int(rest.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// The bundled copy: inside Contents/Resources when running as a packaged .app (see
    /// the Bundle .app step in .github/workflows/build-installers.yml), or alongside the
    /// app/ checkout when running from `swift run` during development.
    static func bundledScriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "AddressablesModExporter", withExtension: "cs") {
            return url
        }
        // Dev fallback: <repo>/app/mac/.build/... -> <repo>/app/unity/AddressablesModExporter.cs
        let devURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // V25ModBuilder
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // mac
            .deletingLastPathComponent() // app/
            .appendingPathComponent("unity/AddressablesModExporter.cs")
        return FileManager.default.fileExists(atPath: devURL.path) ? devURL : nil
    }

    @discardableResult
    static func ensureInstalled(projectPath: String) -> Status {
        guard let bundledURL = bundledScriptURL(),
              let bundled = try? String(contentsOf: bundledURL, encoding: .utf8) else {
            return .failed("couldn't read bundled exporter script")
        }

        let target = (projectPath as NSString).appendingPathComponent(exporterScriptRelativePath)
        let existing = try? String(contentsOfFile: target, encoding: .utf8)

        if let existing, exporterScriptVersion(existing) >= exporterScriptVersion(bundled) {
            return .current
        }

        do {
            try FileManager.default.createDirectory(
                atPath: (target as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try bundled.write(toFile: target, atomically: true, encoding: .utf8)
        } catch {
            return .failed("couldn't install exporter script: \(error.localizedDescription)")
        }
        return existing == nil ? .installed : .updated
    }
}
