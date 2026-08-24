// Pure helpers for spotting a Unity Editor that already has a given project open.
//
// Kept electron-free (and side-effect-free) so the matching rules can be unit-tested
// against real `ps` / Win32_Process output without launching a Unity Editor.

// Only the Editor binary itself counts. Matching on argv[0] rather than anywhere in the
// command line keeps out (a) Unity's own helper processes - licensing client, package
// manager, asset import workers, which die with the parent anyway - and (b) unrelated
// processes such as a shell or editor whose arguments merely mention the project path.
function isUnityEditorCommand(cmd) {
  const trimmed = String(cmd).trim();
  // Windows command lines quote argv[0] when the install path contains spaces
  // ("C:\Program Files\Unity\...\Unity.exe" -projectPath ...), so a plain space split
  // would truncate it mid-path.
  const argv0 = trimmed.startsWith('"')
    ? trimmed.slice(1, trimmed.indexOf('"', 1) === -1 ? undefined : trimmed.indexOf('"', 1))
    : trimmed.split(' ')[0];
  return /(^|[\\/])Unity(\.exe)?$/i.test(argv0);
}

function commandLineTargetsProject(cmd, normalizedProjectPath) {
  const needle = String(normalizedProjectPath).replace(/[\\/]+/g, '/').toLowerCase();
  if (!needle) return false;
  const haystack = String(cmd).replace(/[\\/]+/g, '/').toLowerCase();
  // Require a path boundary so /foo/Bar doesn't match a launch of /foo/BarBaz.
  const index = haystack.indexOf(needle);
  if (index < 0) return false;
  const nextChar = haystack[index + needle.length];
  return nextChar === undefined || nextChar === '/' || nextChar === ' ' || nextChar === '"';
}

// psOutput is `ps -eo pid=,args=` output: one "<pid> <full command line>" per line.
function parseUnityProcesses(psOutput, normalizedProjectPath, ownPids = new Set()) {
  const matches = [];
  for (const line of String(psOutput).split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const spaceAt = trimmed.indexOf(' ');
    if (spaceAt < 0) continue;
    const pid = parseInt(trimmed.slice(0, spaceAt), 10);
    const cmd = trimmed.slice(spaceAt + 1);
    if (!pid || ownPids.has(pid)) continue;
    if (!isUnityEditorCommand(cmd)) continue;
    if (!commandLineTargetsProject(cmd, normalizedProjectPath)) continue;
    matches.push({ pid, cmd });
  }
  return matches;
}

module.exports = { parseUnityProcesses, isUnityEditorCommand, commandLineTargetsProject };
