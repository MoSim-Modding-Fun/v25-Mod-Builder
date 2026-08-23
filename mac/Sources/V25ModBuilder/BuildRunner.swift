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

    /// All successful platforms' output zip paths, in build order - the GitHub release
    /// step's asset list. Derived from outputPathsByPlatform in the ORIGINAL platform
    /// order, so a retry that only rebuilds the failed platforms still releases every
    /// platform's zips, not just the retried ones - mirrors renderer.js's
    /// `buildContext.platforms.flatMap((p) => outputPathsByPlatform[p] || [])`.
    var allOutputPaths: [String] {
        requestedPlatforms.flatMap { outputPathsByPlatform[$0] ?? [] }
    }
    @Published var releaseStatus: SegmentStatus = .pending
    @Published var releaseConsoleLines: [ConsoleLine] = []

    // Everything a retry needs to re-run a subset of the original request unchanged -
    // mirrors renderer.js's `buildContext` (groups/platforms/outputDir kept as-is across
    // retries; only the platform SUBSET passed to runProcess changes).
    private var requestedGroups: [ModGroup] = []
    private var requestedPlatforms: [PlatformTarget] = []
    private var requestedProjectPath: String = ""
    private var requestedUnityPath: String = ""
    private var requestedOutputDir: String?

    // platform -> that platform's successful output zip paths, kept (not overwritten with
    // an empty array) across a retry so allOutputPaths above can still cover platforms
    // that succeeded on an earlier attempt. Mirrors renderer.js's outputPathsByPlatform.
    private var outputPathsByPlatform: [PlatformTarget: [String]] = [:]

    /// Platforms from the original request that haven't succeeded yet - the ones that
    /// failed, plus any that never got to run because an earlier platform's failure
    /// stopped the loop. Mirrors renderer.js's platformsNeedingBuild(). Drives both the
    /// RETRY button's visibility/label in ContentView and retryFailed()'s platform list.
    var platformsNeedingBuild: [PlatformTarget] {
        requestedPlatforms.filter { platformStatus[$0] != .success }
    }

    private let failureMarkers = [
        "error CS",
        "Aborting batchmode due to failure",
        "Scripts have compiler errors",
        "crash has been intercepted",
        "Multiple Unity instances cannot open the same project",
    ]

    func run(projectPath rawProjectPath: String, unityPath: String, groups: [ModGroup], platforms: [PlatformTarget], outputDir: String?) async {
        // Normalized the same way as ProjectService.resolveProjectFast() so this always
        // matches the key an in-flight auto-register scan for the same project is using.
        let projectPath = (rawProjectPath as NSString).standardizingPath

        requestedGroups = groups
        requestedPlatforms = platforms
        requestedProjectPath = projectPath
        requestedUnityPath = unityPath
        requestedOutputDir = outputDir
        outputPathsByPlatform = [:]

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
        releaseStatus = .pending
        releaseConsoleLines = []

        await runPlatforms(platforms)
    }

    /// Re-runs only the platforms still owed a successful build (see
    /// platformsNeedingBuild), reusing the groups/project/unity/outputDir from the
    /// original run() call unchanged. Mirrors renderer.js's retry-btn click handler:
    /// clears only the retried platforms' console lines, status badges, and progress
    /// segments, leaving already-succeeded platforms' output on screen untouched.
    func retryFailed() async {
        let retryPlatforms = platformsNeedingBuild
        guard !retryPlatforms.isEmpty else { return }

        for p in retryPlatforms {
            consoleLines[p] = []
            platformStatus[p] = .pending
        }
        for idx in progressSegments.indices where retryPlatforms.contains(progressSegments[idx].platform) {
            progressSegments[idx].status = .pending
        }
        // A previous attempt may have already marked the release failed/skipped; a
        // retry gives it another chance once the platforms it depends on succeed.
        releaseStatus = .pending

        await runPlatforms(retryPlatforms)
    }

    /// Shared by run() and retryFailed(): actually drives Unity for the given platform
    /// subset. Split out so a retry can pass just the still-failing platforms without
    /// duplicating the pre-flight check, per-platform loop, or output-move logic.
    private func runPlatforms(_ platforms: [PlatformTarget]) async {
        let projectPath = requestedProjectPath
        let unityPath = requestedUnityPath
        let outputDir = requestedOutputDir
        let selectedGroups = requestedGroups.filter { $0.checked }

        isRunning = true
        defer { isRunning = false }

        // The build runs entirely through the bundled Editor script's -executeMethod entry
        // points, and the public template project doesn't ship that script - so make sure
        // it's there before spending any time launching Unity. Same shape as main.js's
        // run-build handler's "Unity executable not found" early-out: mark the first
        // platform failed with a reason and stop, no Unity process gets spawned.
        if case .failed(let installError) = UnityScriptInstaller.ensureInstalled(projectPath: projectPath) {
            failEarly(platforms: platforms, reason: "couldn't install exporter script: \(installError)")
            return
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

            // The already-open-in-Unity check runs INSIDE the queue slot (see
            // UnityLaunchQueue's doc comment) - if the user cancels that prompt, abort
            // this platform's build the same way a missing Unity executable would.
            let abortReason: String? = await UnityLaunchQueue.shared.enqueue(projectPath: projectPath) { clear in
                switch clear {
                case .ok:
                    _ = await Self.runProcess(executable: unityPath, arguments: args)
                    return nil
                case .aborted(let reason):
                    return reason
                }
            }
            tailer.stop()
            tailer.drainOnce() // catch anything written between the last poll and process exit

            let logContent = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
            let builtPaths = selectedGroups.map { builtZipPath(projectPath: projectPath, group: $0, platform: platform) }
            let missing = builtPaths.filter { !FileManager.default.fileExists(atPath: $0) }
            let failureMarker = failureMarkers.first { logContent.contains($0) }

            var failed = abortReason != nil || failureMarker != nil || !missing.isEmpty
            var reason: String? = abortReason
            if reason == nil, let marker = failureMarker { reason = "build log contains \"\(marker)\"" }
            else if reason == nil, !missing.isEmpty { reason = "missing expected output: \(missing.joined(separator: "; "))" }

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
                outputPathsByPlatform[platform] = finalPaths
            }
        }
    }

    /// True once every platform from the ORIGINAL request (not just this attempt's
    /// subset) has a success outcome - stays correct across a retry because
    /// platformStatus for already-succeeded platforms is never touched by retryFailed().
    var allRequestedPlatformsSucceeded: Bool {
        !requestedPlatforms.isEmpty && requestedPlatforms.allSatisfy { platformStatus[$0] == .success }
    }

    /// Mirrors main.js's `create-github-release` IPC handler: always releases to the
    /// Unity project's own repo (not this tool's), via the user's local `gh` CLI.
    func createGitHubRelease(tag: String, title: String, notes: String) async {
        releaseStatus = .running
        appendReleaseLine("Creating GitHub release on \(Self.githubReleaseRepo)...")

        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmedTag.isEmpty else {
            releaseStatus = .failed
            appendReleaseLine("No release tag given.", kind: .failure)
            return
        }
        guard !allOutputPaths.isEmpty else {
            releaseStatus = .failed
            appendReleaseLine("No build output to attach.", kind: .failure)
            return
        }

        var args = ["release", "create", trimmedTag] + allOutputPaths + ["--repo", Self.githubReleaseRepo]
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        args += ["--title", trimmedTitle.isEmpty ? trimmedTag : trimmedTitle]
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        args += ["--notes", trimmedNotes.isEmpty ? "Built by v25 Mod Builder." : trimmedNotes]

        let (code, output) = await Self.runGh(arguments: args)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            appendReleaseLine(String(line), kind: code == 0 ? .success : .failure)
        }
        releaseStatus = code == 0 ? .success : .failed
        appendReleaseLine(code == 0 ? "=== RELEASE : SUCCESS ===" : "=== RELEASE : FAILED ===", kind: code == 0 ? .success : .failure)
    }

    static let githubReleaseRepo = "MoSim-Modding-Fun/MoSim-Reefscape-Public"

    private func appendReleaseLine(_ text: String, kind: ConsoleLine.Kind = .normal) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        releaseConsoleLines.append(ConsoleLine(time: formatter.string(from: Date()), text: text, kind: kind))
    }

    private static func runGh(arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh"] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus, output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    /// Mirrors main.js's runUnityBuildProcess(): registers the spawned PID with the
    /// launch queue's ownUnityPids set before the process can be observed by the
    /// already-open check, and releases it on exit - a headless build Unity itself
    /// launched here must never be mistaken for a foreign Editor to offer killing.
    private static func runProcess(executable: String, arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { proc in
                let pid = proc.processIdentifier
                Task { @MainActor in UnityLaunchQueue.shared.releaseOwnPid(pid) }
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
                UnityLaunchQueue.shared.trackOwnPid(process.processIdentifier)
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    /// Marks the build failed before any platform actually ran - e.g. a pre-flight check
    /// like the exporter-script install failed, or the "project already open in Unity"
    /// prompt got cancelled. Mirrors the shape of the per-platform failure block further
    /// down (first platform's status/console show the reason) since there's no separate
    /// top-level error field in this model, same as main.js returning a single
    /// `{ target: null, status: 'failed', error }` entry from run-build.
    private func failEarly(platforms: [PlatformTarget], reason: String) {
        guard let first = platforms.first else { return }
        currentPlatform = first
        platformStatus[first] = .failed
        appendLine(platform: first, text: "=== \(first.rawValue) : FAILED ===", kind: .failure)
        appendLine(platform: first, text: "Reason: \(reason)", kind: .failure)
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
