import Foundation
import Combine

/// Mirrors main.js's run-build IPC handler in the Electron app almost line for line:
/// same Unity CLI args, same failure markers, same output-move logic, same log-line
/// parsing for per-group progress. Drives the exact same Editor.AddressablesModExporter
/// on the Unity side - no changes needed there for this app to work.
@MainActor
final class BuildRunner: ObservableObject {
    @Published var consoleLines: [PlatformTarget: [ConsoleLine]] = [:]
    @Published var platformStatus: [PlatformTarget: SegmentStatus] = [:]
    @Published var progressSegments: [ProgressSegment] = []
    @Published var isRunning = false
    /// The platform currently building - the view follows this to auto-switch the
    /// console tab as each platform finishes and the next one starts.
    @Published var currentPlatform: PlatformTarget?

    private let failureMarkers = [
        "error CS",
        "Aborting batchmode due to failure",
        "Scripts have compiler errors",
        "crash has been intercepted",
        "Multiple Unity instances cannot open the same project",
    ]

    func run(projectPath: String, unityPath: String, groups: [ModGroup], platforms: [PlatformTarget], outputDir: String?) async {
        isRunning = true
        defer { isRunning = false }

        let selectedGroups = groups.filter { $0.checked }
        progressSegments = platforms.flatMap { platform in
            selectedGroups.map { g in
                ProgressSegment(
                    platform: platform,
                    group: g.name,
                    zipName: g.zipName.trimmingCharacters(in: .whitespaces).isEmpty ? g.name : g.zipName,
                    version: g.version.trimmingCharacters(in: .whitespaces)
                )
            }
        }
        for p in platforms {
            consoleLines[p] = []
            platformStatus[p] = .pending
        }

        let logDir = (projectPath as NSString).appendingPathComponent("Tools/build-logs")
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        let groupsArg = selectedGroups.map { $0.name }.joined(separator: "|")
        let versionsArg = selectedGroups.map { $0.version }.joined(separator: "|")
        let zipNamesArg = selectedGroups.map { $0.zipName }.joined(separator: "|")
        let hasVersions = selectedGroups.contains { !$0.version.trimmingCharacters(in: .whitespaces).isEmpty }
        let hasZipNames = selectedGroups.contains { !$0.zipName.trimmingCharacters(in: .whitespaces).isEmpty }

        for platform in platforms {
            platformStatus[platform] = .running
            currentPlatform = platform

            let logFile = (logDir as NSString).appendingPathComponent("build-\(platform.rawValue).log")
            try? FileManager.default.removeItem(atPath: logFile)
            FileManager.default.createFile(atPath: logFile, contents: nil)

            var args = [
                "-batchmode", "-quit", "-nographics",
                "-projectPath", projectPath,
                "-buildTarget", platform.buildTargetArg,
                "-executeMethod", "Editor.AddressablesModExporter.BuildFromCommandLine",
                "-groups", groupsArg,
                "-logFile", logFile,
            ]
            if hasVersions { args += ["-versions", versionsArg] }
            if hasZipNames { args += ["-zipNames", zipNamesArg] }

            let tailer = LogTailer(path: logFile) { [weak self] line in
                guard let self else { return }
                self.appendLine(platform: platform, text: line)
                self.updateProgress(fromLine: line, platform: platform)
            }
            tailer.start()

            _ = await Self.runProcess(executable: unityPath, arguments: args)
            tailer.stop()
            tailer.drainOnce() // catch anything written between the last poll and process exit

            let logContent = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
            let builtPaths = selectedGroups.map { builtZipPath(projectPath: projectPath, group: $0, platform: platform) }
            let missing = builtPaths.filter { !FileManager.default.fileExists(atPath: $0) }
            let failureMarker = failureMarkers.first { logContent.contains($0) }

            var failed = failureMarker != nil || !missing.isEmpty
            var reason: String?
            if let marker = failureMarker { reason = "build log contains \"\(marker)\"" }
            else if !missing.isEmpty { reason = "missing expected output: \(missing.joined(separator: "; "))" }

            var finalPaths = builtPaths
            if !failed, let outputDir, !outputDir.isEmpty {
                let modsDir = (projectPath as NSString).appendingPathComponent("Mods")
                if (outputDir as NSString).standardizingPath != (modsDir as NSString).standardizingPath {
                    do {
                        finalPaths = try builtPaths.map { src in
                            try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
                            let dest = (outputDir as NSString).appendingPathComponent((src as NSString).lastPathComponent)
                            if FileManager.default.fileExists(atPath: dest) {
                                try FileManager.default.removeItem(atPath: dest)
                            }
                            try FileManager.default.moveItem(atPath: src, toPath: dest)
                            return dest
                        }
                    } catch {
                        failed = true
                        reason = "built successfully but failed to move output to \"\(outputDir)\": \(error.localizedDescription)"
                    }
                }
            }

            if failed {
                platformStatus[platform] = .failed
                appendLine(platform: platform, text: "=== \(platform.rawValue) : FAILED ===", kind: .failure)
                appendLine(platform: platform, text: "Reason: \(reason ?? "unknown")", kind: .failure)
                break
            } else {
                platformStatus[platform] = .success
                appendLine(platform: platform, text: "=== \(platform.rawValue) : SUCCESS ===", kind: .success)
                for p in finalPaths {
                    appendLine(platform: platform, text: p, kind: .success)
                }
            }
        }
    }

    private static func runProcess(executable: String, arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    private func appendLine(platform: PlatformTarget, text: String, kind: ConsoleLine.Kind = .normal) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: Date())
        consoleLines[platform, default: []].append(ConsoleLine(time: time, text: text, kind: kind))
    }

    private func updateProgress(fromLine line: String, platform: PlatformTarget) {
        if let groupName = Self.match(line, prefix: "Building addressables for: ", suffix: " (target:") {
            setSegment(platform: platform, group: groupName, status: .running)
            return
        }
        if let groupName = Self.match(line, prefix: "Addressables build failed for '", suffix: "'") {
            setSegment(platform: platform, group: groupName, status: .failed)
            return
        }
        if let range = line.range(of: "Zipped mod folder to ") {
            let filePath = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let fileName = (filePath as NSString).lastPathComponent
            if let idx = progressSegments.firstIndex(where: {
                $0.platform == platform && $0.status == .running && expectedFileName(for: $0) == fileName
            }) {
                progressSegments[idx].status = .success
            }
        }
    }

    private static func match(_ line: String, prefix: String, suffix: String) -> String? {
        guard let prefixRange = line.range(of: prefix) else { return nil }
        let rest = line[prefixRange.upperBound...]
        guard let suffixRange = rest.range(of: suffix) else { return nil }
        return String(rest[..<suffixRange.lowerBound])
    }

    private func setSegment(platform: PlatformTarget, group: String, status: SegmentStatus) {
        if let idx = progressSegments.firstIndex(where: { $0.platform == platform && $0.group == group }) {
            progressSegments[idx].status = status
        }
    }

    private func expectedFileName(for seg: ProgressSegment) -> String {
        let label = seg.platform.zipLabel
        return seg.version.isEmpty ? "\(seg.zipName) \(label).zip" : "\(seg.zipName) \(seg.version) \(label).zip"
    }

    private func builtZipPath(projectPath: String, group: ModGroup, platform: PlatformTarget) -> String {
        let zipName = group.zipName.trimmingCharacters(in: .whitespaces).isEmpty ? group.name : group.zipName
        let version = group.version.trimmingCharacters(in: .whitespaces)
        let label = platform.zipLabel
        let fileName = version.isEmpty ? "\(zipName) \(label).zip" : "\(zipName) \(version) \(label).zip"
        let modsDir = (projectPath as NSString).appendingPathComponent("Mods")
        return (modsDir as NSString).appendingPathComponent(fileName)
    }
}

/// Polls a growing file for new lines, like `tail -f`, with no external dependencies -
/// mirrors main.js's tailLogFile() (same 300ms poll interval, same partial-last-line
/// carry-over handling).
final class LogTailer {
    private let path: String
    private let onLine: (String) -> Void
    private var timer: Timer?
    private var offset: UInt64 = 0
    private var carry: String = ""

    init(path: String, onLine: @escaping (String) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func drainOnce() {
        poll()
    }

    private func poll() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value, size > offset,
              let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = size
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        let combined = carry + chunk
        var lines = combined.components(separatedBy: "\n")
        carry = lines.removeLast()
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            onLine(line)
        }
    }
}
