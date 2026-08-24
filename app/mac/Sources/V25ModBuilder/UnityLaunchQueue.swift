import Foundation
import AppKit

/// Mirrors main.js's runUnityBuild() queue: Unity refuses to open a project that's
/// already locked by another instance of itself (Temp/UnityLockfile), so the
/// auto-register-mod-folders scan (ProjectService) and a real build (BuildRunner) must
/// never launch Unity against the same project concurrently. Every Unity launch for a
/// given project path is serialized through here instead.
///
/// Also owns the "project is already open in a foreign Unity Editor" check (mirrors
/// main.js's ensureProjectNotOpenInUnity): that check has to run INSIDE the queued slot,
/// not before it, or it would race a queued sibling launch that hasn't taken the lock
/// yet and hasn't registered its own spawned PID as "ours" - see main.js's comment on
/// runUnityBuild for the same reasoning.
@MainActor
final class UnityLaunchQueue {
    static let shared = UnityLaunchQueue()
    private var tails: [String: Task<Void, Never>] = [:]

    /// PIDs of Unity processes THIS app started. The already-open check below looks for
    /// Unity processes holding the project, and must never offer to kill our own
    /// headless build/scan - only a real Editor the user has open.
    private var ownUnityPids: Set<Int32> = []

    enum LaunchResult {
        case ok
        case aborted(reason: String)
    }

    /// Runs `operation` once this project's launch slot is free. `operation` receives a
    /// `LaunchResult` telling it whether it's clear to actually spawn Unity: `.ok`, or
    /// `.aborted(reason:)` if the project turned out to be open in a foreign Editor and
    /// the user cancelled. Callers that don't care about the distinction (best-effort
    /// scans) can just check for `.ok` and skip the launch silently otherwise.
    @discardableResult
    func enqueue<T>(projectPath: String, _ operation: @escaping (LaunchResult) async -> T) async -> T {
        let previous = tails[projectPath]
        let task = Task { () -> T in
            _ = await previous?.value
            let clear = await ensureProjectNotOpenInUnity(projectPath: projectPath)
            return await operation(clear)
        }
        // The stored tail only ever gets awaited, never read, so it's erased to Task<Void,
        // Never> - that's what lets calls returning different T values chain onto the same
        // per-project queue. (Writing the result back into a captured `var` instead would
        // be a mutation from inside a concurrently-executing closure, which doesn't compile.)
        tails[projectPath] = Task { _ = await task.value }
        return await task.value
    }

    /// Registers a PID this app just spawned so the already-open check never mistakes it
    /// for a foreign Editor. Callers must call `releaseOwnPid` once the process exits.
    func trackOwnPid(_ pid: Int32) {
        ownUnityPids.insert(pid)
    }

    func releaseOwnPid(_ pid: Int32) {
        ownUnityPids.remove(pid)
    }

    // MARK: - "Project is already open in Unity" handling

    private func lockFileExists(_ projectPath: String) -> Bool {
        let lockPath = (projectPath as NSString).appendingPathComponent("Temp/UnityLockfile")
        return FileManager.default.fileExists(atPath: lockPath)
    }

    /// Unity Editors opened through Unity Hub (every platform) carry the project directory
    /// in their command line, which is what lets us tell "this project is open" apart from
    /// "some unrelated Unity is running". Falls back to no-match rather than guessing.
    private func findForeignUnityProcesses(projectPath: String) async -> [UnityProcess.Match] {
        let normalized = (projectPath as NSString).standardizingPath
        let ps = await Self.runPS()
        return UnityProcess.parseUnityProcesses(ps, normalizedProjectPath: normalized, ownPids: ownUnityPids)
    }

    private static func runPS() async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-eo", "pid=,args="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    private func killProcess(pid: Int32, force: Bool) {
        kill(pid, force ? SIGKILL : SIGTERM)
    }

    private func processStillAlive(pid: Int32) -> Bool {
        // Signal 0 sends nothing but still fails with ESRCH if the process is gone -
        // the standard "is this pid alive" probe, mirrors main.js's process.kill(pid, 0).
        kill(pid, 0) == 0
    }

    private func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    private func ensureProjectNotOpenInUnity(projectPath: String) async -> LaunchResult {
        guard lockFileExists(projectPath) else { return .ok }

        let foreign = await findForeignUnityProcesses(projectPath: projectPath)
        // A stale lockfile with no live Editor behind it is harmless - Unity clears it
        // itself on next successful launch.
        guard !foreign.isEmpty else { return .ok }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This project is currently open in the Unity Editor."
        alert.informativeText =
            "Unity can't open the same project twice, so the build can't run while the Editor " +
            "has it open.\n\nClosing Unity from here will not save your work first - save anything " +
            "you need in Unity before continuing."
        alert.addButton(withTitle: "Close Unity and continue") // index 0 / .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel build")              // index 1 / .alertSecondButtonReturn
        // Matches main.js's defaultId: 1, cancelId: 1 - Cancel is both the Return-key
        // default and what Escape triggers, so an accidental keypress never kills Unity.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else {
            return .aborted(reason: "Project is open in the Unity Editor and the build was cancelled.")
        }

        for proc in foreign { killProcess(pid: proc.pid, force: false) }

        // Give the Editor a chance to shut down cleanly (and release the lock) before forcing it.
        var waited = 0
        while waited < 20000 {
            await sleep(ms: 500)
            waited += 500
            if !foreign.contains(where: { processStillAlive(pid: $0.pid) }) { break }
        }
        for proc in foreign where processStillAlive(pid: proc.pid) {
            killProcess(pid: proc.pid, force: true)
        }

        // Unity removes Temp/UnityLockfile on exit; if it was killed hard, clear the
        // leftover ourselves so the next launch doesn't trip over it.
        waited = 0
        while waited < 10000 {
            if !lockFileExists(projectPath) { break }
            await sleep(ms: 500)
            waited += 500
        }
        if lockFileExists(projectPath) {
            let stillForeign = await findForeignUnityProcesses(projectPath: projectPath)
            if stillForeign.isEmpty {
                let lockPath = (projectPath as NSString).appendingPathComponent("Temp/UnityLockfile")
                try? FileManager.default.removeItem(atPath: lockPath)
            }
        }

        return .ok
    }
}
