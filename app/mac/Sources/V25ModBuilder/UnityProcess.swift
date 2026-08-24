import Foundation

/// Swift port of unity-process.js's pure helpers - keep the two in sync.
///
/// Kept free of Process/NSAlert orchestration (that lives in UnityLaunchQueue) so the
/// matching rules themselves stay easy to read and reason about against real `ps`
/// output, mirroring why the Electron side split this into its own file too.
enum UnityProcess {
    struct Match {
        let pid: Int32
        let cmd: String
    }

    /// Only the Editor binary itself counts. Matching on argv[0] rather than anywhere in
    /// the command line keeps out (a) Unity's own helper processes - licensing client,
    /// package manager, asset import workers, which die with the parent anyway - and (b)
    /// unrelated processes such as a shell or editor whose arguments merely mention the
    /// project path.
    static func isUnityEditorCommand(_ cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespaces)
        // Command lines quote argv[0] when the install path contains spaces
        // ("/Applications/Unity/.../Unity" -projectPath ...), so a plain space split
        // would truncate it mid-path.
        let argv0: Substring
        if trimmed.hasPrefix("\"") {
            let rest = trimmed.dropFirst()
            if let closeIdx = rest.firstIndex(of: "\"") {
                argv0 = rest[rest.startIndex..<closeIdx]
            } else {
                argv0 = rest
            }
        } else {
            argv0 = trimmed.prefix(while: { $0 != " " })
        }
        return matchesUnityEditorBinaryName(String(argv0))
    }

    /// Mirrors JS's `/(^|[\\/])Unity(\.exe)?$/i` without needing NSRegularExpression.
    private static func matchesUnityEditorBinaryName(_ argv0: String) -> Bool {
        let normalized = argv0.replacingOccurrences(of: "\\", with: "/")
        let lastComponent = normalized.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? normalized
        let lower = lastComponent.lowercased()
        return lower == "unity" || lower == "unity.exe"
    }

    /// Requires a path boundary so /foo/Bar doesn't match a launch of /foo/BarBaz.
    /// Compares case-insensitively with backslashes normalized to forward slashes, same
    /// as the Electron side.
    static func commandLineTargetsProject(_ cmd: String, normalizedProjectPath: String) -> Bool {
        let needle = normalizedProjectPath.replacingOccurrences(of: "\\", with: "/").lowercased()
        guard !needle.isEmpty else { return false }
        let haystack = cmd.replacingOccurrences(of: "\\", with: "/").lowercased()
        guard let range = haystack.range(of: needle) else { return false }

        let afterIdx = range.upperBound
        guard afterIdx < haystack.endIndex else { return true } // matched at end-of-string
        let nextChar = haystack[afterIdx]
        return nextChar == "/" || nextChar == " " || nextChar == "\""
    }

    /// psOutput is `ps -eo pid=,args=` output: one "<pid> <full command line>" per line.
    static func parseUnityProcesses(_ psOutput: String, normalizedProjectPath: String, ownPids: Set<Int32> = []) -> [Match] {
        var matches: [Match] = []
        for rawLine in psOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            let pidStr = trimmed[trimmed.startIndex..<spaceIdx]
            let cmd = String(trimmed[trimmed.index(after: spaceIdx)...])
            guard let pid = Int32(pidStr), pid != 0, !ownPids.contains(pid) else { continue }
            guard isUnityEditorCommand(cmd) else { continue }
            guard commandLineTargetsProject(cmd, normalizedProjectPath: normalizedProjectPath) else { continue }
            matches.append(Match(pid: pid, cmd: cmd))
        }
        return matches
    }
}
