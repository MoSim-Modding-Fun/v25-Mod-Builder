import Foundation

/// Mirrors main.js's runUnityBuild() queue: Unity refuses to open a project that's
/// already locked by another instance of itself (Temp/UnityLockfile), so the
/// auto-register-mod-folders scan (ProjectService) and a real build (BuildRunner) must
/// never launch Unity against the same project concurrently. Every Unity launch for a
/// given project path is serialized through here instead.
@MainActor
final class UnityLaunchQueue {
    static let shared = UnityLaunchQueue()
    private var tails: [String: Task<Void, Never>] = [:]

    func enqueue(projectPath: String, _ operation: @escaping () async -> Void) async {
        let previous = tails[projectPath]
        let task = Task {
            _ = await previous?.value
            await operation()
        }
        tails[projectPath] = task
        await task.value
    }
}
