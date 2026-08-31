const { app, BrowserWindow, ipcMain, dialog, screen } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');
const { ensureExporterScriptInstalled } = require('./unity-script-installer');
const { parseUnityProcesses, commandLineTargetsProject, isUnityEditorCommand } = require('./unity-process');

let mainWindow;
const settingsPath = () => path.join(app.getPath('userData'), 'settings.json');

// One-time migration: this app was renamed from "MoSim Mod Builder" (package.json name
// "mosim-modbuilder") to "v25 Mod Builder" ("v25-mod-builder"), which changed Electron's
// default userData directory. Without this, settings.json - remembered project, Unity
// path, output folder - would look freshly empty on first launch after the rename.
function migrateSettingsFromOldName() {
  if (fs.existsSync(settingsPath())) return;
  const oldPath = path.join(path.dirname(app.getPath('userData')), 'mosim-modbuilder', 'settings.json');
  if (!fs.existsSync(oldPath)) return;
  fs.mkdirSync(path.dirname(settingsPath()), { recursive: true });
  fs.copyFileSync(oldPath, settingsPath());
}

function loadSettings() {
  try {
    return JSON.parse(fs.readFileSync(settingsPath(), 'utf8'));
  } catch {
    return {};
  }
}

function saveSettings(settings) {
  fs.mkdirSync(path.dirname(settingsPath()), { recursive: true });
  fs.writeFileSync(settingsPath(), JSON.stringify(settings, null, 2));
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 480,
    height: 300,
    minWidth: 420,
    minHeight: 260,
    // Windows taskbar/title-bar icons render blurry from a single arbitrary-size PNG
    // (it just gets scaled on the fly) - the multi-resolution .ico renders crisp instead.
    // Elsewhere, the pre-sized 512px copy rather than the 2134px source: identical at
    // icon scale, without decoding ~18 MB of RGBA to draw a 32px title-bar icon.
    icon: path.join(__dirname, 'build', process.platform === 'win32' ? 'icon.ico' : 'icons/512x512.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

app.whenReady().then(() => {
  migrateSettingsFromOldName();
  createWindow();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});

// ---------- Unity project helpers ----------

function readProjectVersion(projectPath) {
  const versionFile = path.join(projectPath, 'ProjectSettings', 'ProjectVersion.txt');
  const content = fs.readFileSync(versionFile, 'utf8');
  const match = content.match(/m_EditorVersion:\s*(\S+)/);
  return match ? match[1] : null;
}

function defaultUnityPaths(version) {
  const home = os.homedir();
  switch (process.platform) {
    case 'win32':
      return [`C:\\Program Files\\Unity\\Hub\\Editor\\${version}\\Editor\\Unity.exe`];
    case 'darwin':
      return [`/Applications/Unity/Hub/Editor/${version}/Unity.app/Contents/MacOS/Unity`];
    case 'linux':
      return [
        path.join(home, 'Unity', 'Hub', 'Editor', version, 'Editor', 'Unity'),
        `/opt/unityhub/Editor/${version}/Editor/Unity`,
      ];
    default:
      return [];
  }
}

function detectUnity(version) {
  for (const candidate of defaultUnityPaths(version)) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

// Groups Unity creates by default, plus LynkMod and MechTechMod, which ship in the
// repo as example/template mods rather than something meant to be built and distributed.
const RESERVED_GROUP_NAMES = new Set([
  'Built In Data', 'EditorSceneList', 'Default Local Group', 'LynkMod', 'MechTechMod',
  // The example mod that ships in the public template project - auto-registration would
  // otherwise surface it as a buildable group for every single user.
  'LynkModOfficial',
]);

// Every group actually defined in the project, reserved ones included.
function listAllAddressableGroupNames(projectPath) {
  const groupsDir = path.join(projectPath, 'Assets', 'AddressableAssetsData', 'AssetGroups');
  if (!fs.existsSync(groupsDir)) return [];

  const names = [];
  for (const entry of fs.readdirSync(groupsDir, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith('.asset')) continue;
    const content = fs.readFileSync(path.join(groupsDir, entry.name), 'utf8');
    const match = content.match(/m_GroupName:\s*(.+)/);
    if (!match) continue;
    names.push(match[1].trim());
  }
  return names.sort();
}

// The buildable groups shown in the UI.
function listAddressableGroups(projectPath) {
  return listAllAddressableGroupNames(projectPath).filter((name) => !RESERVED_GROUP_NAMES.has(name));
}

// ---------- IPC: settings & project selection ----------

ipcMain.handle('load-settings', () => loadSettings());

// Folder that holds one subfolder per mod (robot(s) + modpack metadata) - must match
// AddressablesModExporter.cs's RobotsRoot constant exactly.
const ROBOTS_ROOT_REL = ['Assets', 'Prefabs', 'Reefscape', 'Robots', 'Mods'];

// Every asset GUID already claimed by some group's entry list. Entries are the
// "- m_GUID:" list items under m_SerializeEntries; the group's own bare "m_GUID:" line
// has no leading dash, so this deliberately doesn't pick it up.
function listRegisteredEntryGuids(projectPath) {
  const groupsDir = path.join(projectPath, 'Assets', 'AddressableAssetsData', 'AssetGroups');
  if (!fs.existsSync(groupsDir)) return new Set();

  const guids = new Set();
  for (const entry of fs.readdirSync(groupsDir, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith('.asset')) continue;
    const content = fs.readFileSync(path.join(groupsDir, entry.name), 'utf8');
    for (const match of content.matchAll(/-\s*m_GUID:\s*([0-9a-f]+)/g)) guids.add(match[1]);
  }
  return guids;
}

// Unity stores an asset's GUID in its sibling .meta file.
function readAssetGuid(assetPath) {
  try {
    const meta = fs.readFileSync(`${assetPath}.meta`, 'utf8');
    const match = meta.match(/^guid:\s*([0-9a-f]+)/m);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

// Cheap filesystem-only pre-check so a normal project select stays instant; Unity only
// gets launched (slow) when there's actually a mod folder no group has claimed yet.
//
// Matches on GUID rather than on folder-vs-group name, exactly like AutoRegisterModGroups
// does on the Unity side. Name matching gets this wrong in both directions and each
// mistake costs a full, pointless Unity launch on every project load: a group whose name
// drifted from its folder (folder "Lanternfly" registered as group "Lanternfly Mod")
// looks unregistered forever, and so does any reserved group excluded from the UI list.
function findCandidateModFolders(projectPath) {
  const robotsRoot = path.join(projectPath, ...ROBOTS_ROOT_REL);
  if (!fs.existsSync(robotsRoot)) return [];

  const registered = listRegisteredEntryGuids(projectPath);
  return fs.readdirSync(robotsRoot, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .filter((e) => {
      const guid = readAssetGuid(path.join(robotsRoot, e.name));
      // No .meta yet means Unity hasn't imported it - let the scan handle it.
      return !guid || !registered.has(guid);
    })
    .map((e) => e.name);
}

// The project the renderer most recently asked to load.
let currentProjectPath = null;

// Filesystem-only project read - no Unity launch anywhere in the project-loading path,
// so selecting a project is instant. Shared by the dialog-driven picker and by restoring
// the last-used project on launch, so they can't drift apart.
function resolveProjectFast(projectPath) {
  // A trailing slash (the folder picker can hand back either form depending on
  // platform/GTK version) would otherwise make the same project look like two
  // different keys to the per-projectPath Unity launch queue below, letting two
  // Unity instances race for the same project's lock file after all.
  projectPath = path.resolve(projectPath);

  const assetsDir = path.join(projectPath, 'Assets');
  const versionFile = path.join(projectPath, 'ProjectSettings', 'ProjectVersion.txt');
  if (!fs.existsSync(assetsDir) || !fs.existsSync(versionFile)) {
    return { error: `"${projectPath}" doesn't look like a Unity project (no Assets/ or ProjectSettings/ProjectVersion.txt).` };
  }

  let unityVersion = null;
  try {
    unityVersion = readProjectVersion(projectPath);
  } catch (err) {
    return { error: `Couldn't read ProjectVersion.txt: ${err.message}` };
  }

  const detectedUnityPath = unityVersion ? detectUnity(unityVersion) : null;
  const groups = listAddressableGroups(projectPath);

  return { projectPath, unityVersion, groups, detectedUnityPath };
}

// Mod folders that exist on disk but aren't in any addressable group yet. Purely a
// filesystem read - no Unity launch - so the DETECT button is instant. Nothing is
// created here: an unregistered folder only becomes a real addressable group if the user
// actually picks it and builds it (see EnsureModGroupRegistered in the exporter script).
ipcMain.handle('detect-new-mods', (_event, rawProjectPath) => {
  const projectPath = path.resolve(rawProjectPath);
  if (!fs.existsSync(projectPath)) {
    return { error: `Project "${projectPath}" no longer exists.` };
  }
  return { projectPath, unregistered: findCandidateModFolders(projectPath) };
});

function loadProject(rawProjectPath) {
  const fast = resolveProjectFast(rawProjectPath);
  if (fast.error) return fast;

  // fast.projectPath is normalized (see resolveProjectFast) - use it from here on, not
  // rawProjectPath, or a trailing-slash difference would make the same project look like
  // two different keys to the per-project Unity launch queue.
  const projectPath = fast.projectPath;
  currentProjectPath = projectPath;
  const settings = loadSettings();
  settings.projectPath = projectPath;
  saveSettings(settings);

  return fast;
}

ipcMain.handle('select-project', async () => {
  const result = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory'] });
  if (result.canceled || result.filePaths.length === 0) return null;
  return loadProject(result.filePaths[0]);
});

// Restores the project remembered from the last session (settings.json, in the OS's
// per-user app-data directory — see settingsPath() — so it survives an installed,
// read-only Program Files-style deployment, not just a dev checkout).
ipcMain.handle('load-project', (_event, projectPath) => {
  if (!fs.existsSync(projectPath)) {
    return { error: `Remembered project "${projectPath}" no longer exists.` };
  }
  return loadProject(projectPath);
});

ipcMain.handle('browse-unity-path', async () => {
  const properties = process.platform === 'darwin' ? ['openFile', 'openDirectory'] : ['openFile'];
  const filters = process.platform === 'win32' ? [{ name: 'Unity Editor', extensions: ['exe'] }] : undefined;
  const result = await dialog.showOpenDialog(mainWindow, { properties, filters });
  if (result.canceled || result.filePaths.length === 0) return null;

  let chosen = result.filePaths[0];
  // On macOS the user may pick the .app bundle; resolve to the real binary inside it.
  if (process.platform === 'darwin' && chosen.endsWith('.app')) {
    chosen = path.join(chosen, 'Contents', 'MacOS', 'Unity');
  }

  const settings = loadSettings();
  settings.unityPathOverride = chosen;
  saveSettings(settings);
  return chosen;
});

ipcMain.handle('list-groups', (_event, projectPath) => listAddressableGroups(projectPath));

// Renderer measures the active page's content height (including the live build console,
// which has no internal scroll/cap of its own) and asks for a matching window size, so
// nothing - not even a long-running build's output - ever needs a scrollbar. Clamped to
// the current display's work area since a window taller than the screen would just force
// an OS-level scrollbar right back, defeating the point.
ipcMain.handle('resize-window-height', (_event, contentHeight) => {
  if (!mainWindow) return;
  const [currentWidth] = mainWindow.getContentSize();
  const workAreaHeight = screen.getDisplayMatching(mainWindow.getBounds()).workAreaSize.height;
  const maxHeight = Math.max(260, workAreaHeight - 40); // leave a little room for taskbar/chrome
  const clamped = Math.max(260, Math.min(maxHeight, Math.round(contentHeight)));
  mainWindow.setContentSize(currentWidth, clamped);
});

ipcMain.handle('browse-output-folder', async () => {
  const result = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory', 'createDirectory'] });
  if (result.canceled || result.filePaths.length === 0) return null;

  const chosen = result.filePaths[0];
  const settings = loadSettings();
  settings.outputDirOverride = chosen;
  saveSettings(settings);
  return chosen;
});

// ---------- IPC: build ----------

// `key` is our own identifier (persisted in settings, sent over IPC, used by the
// renderer). `buildTargetArg` is what Unity's -buildTarget actually accepts, which is
// NOT the same vocabulary: macOS is "OSXUniversal" there. Passing an unrecognized name
// leaves the Editor on its previous active build target, so the exporter would happily
// rebuild the *previous* platform's zip and the macOS one would never appear.
const PLATFORM_TARGETS = [
  { key: 'win64', label: 'Windows', buildTargetArg: 'win64' },
  { key: 'osx', label: 'MacOS', buildTargetArg: 'OSXUniversal' },
  { key: 'linux64', label: 'Linux', buildTargetArg: 'linux64' },
];

// Same signal AddressablesModExporter's PowerShell driver uses: Unity's own exit code
// isn't fully trustworthy on its own (licensing-client warnings can taint it even after
// a clean build), so a real failure is a log error/crash marker or a missing output zip.
const FAILURE_MARKERS = [
  'error CS',
  'Aborting batchmode due to failure',
  'Scripts have compiler errors',
  'crash has been intercepted',
  'Multiple Unity instances cannot open the same project',
];

function expectedZipPath(projectPath, group, platformLabel) {
  const zipName = group.zipName && group.zipName.trim() ? group.zipName.trim() : group.name;
  const version = group.version && group.version.trim() ? group.version.trim() : '';
  const archiveName = version
    ? `${zipName} ${version} ${platformLabel}.zip`
    : `${zipName} ${platformLabel}.zip`;
  return path.join(projectPath, 'Mods', archiveName);
}

function findFailureMarker(logContent) {
  return FAILURE_MARKERS.find((marker) => logContent.includes(marker)) || null;
}

function summarizeGroups(groups) {
  return groups
    .map((g) => (g.version && g.version.trim() ? `${g.name}(${g.version.trim()})` : g.name))
    .join(', ');
}

// App-level history log, separate from Unity's own per-platform -logFile output:
// one line per platform build attempt, always recording success or the reason for failure.
function appendHistoryLog(logDir, line) {
  const historyFile = path.join(logDir, 'modbuilder.log');
  const timestamp = new Date().toISOString();
  fs.appendFileSync(historyFile, `[${timestamp}] ${line}\n`);
}

// Unity always writes zips into <projectPath>/Mods/ (that's fixed inside
// AddressablesModExporter.cs, which this app doesn't modify). If the user picked a
// different output folder, move the verified zips there as a post-build step.
function moveFile(src, dest) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  try {
    fs.renameSync(src, dest);
  } catch (err) {
    if (err.code !== 'EXDEV') throw err; // cross-device (e.g. different drive): fall back to copy+delete
    fs.copyFileSync(src, dest);
    fs.unlinkSync(src);
  }
}

// PIDs of Unity processes THIS app started. The "is the project already open?" check
// below looks for Unity processes holding the project, and must never offer to kill our
// own headless build - only a real Editor the user has open.
const ownUnityPids = new Set();

function runUnityBuildProcess(unityPath, args) {
  return new Promise((resolve) => {
    const proc = spawn(unityPath, args, { windowsHide: false });
    if (proc.pid) ownUnityPids.add(proc.pid);
    const done = (result) => {
      if (proc.pid) ownUnityPids.delete(proc.pid);
      resolve(result);
    };
    proc.on('error', (err) => done({ code: -1, error: err.message }));
    proc.on('exit', (code) => done({ code }));
  });
}

// ---------- "project is already open in Unity" handling ----------

function execToString(command, args) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, { windowsHide: true });
    let out = '';
    proc.stdout.on('data', (d) => { out += d; });
    proc.on('error', () => resolve(''));
    proc.on('close', () => resolve(out));
  });
}

// Unity Editors opened through Unity Hub (every platform) carry the project directory in
// their command line, which is what lets us tell "this project is open" apart from "some
// unrelated Unity is running". Falls back to no-match rather than guessing.
async function findForeignUnityProcesses(projectPath) {
  const normalized = path.resolve(projectPath).replace(/[\\/]+$/, '');
  const matches = [];

  if (process.platform === 'win32') {
    const json = await execToString('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      "Get-CimInstance Win32_Process | Where-Object { $_.Name -like 'Unity*' } | " +
      'Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress',
    ]);
    let entries = [];
    try {
      const parsed = JSON.parse(json || '[]');
      entries = Array.isArray(parsed) ? parsed : [parsed];
    } catch { entries = []; }
    for (const entry of entries) {
      if (!entry || !entry.CommandLine || !entry.ProcessId) continue;
      if (ownUnityPids.has(entry.ProcessId)) continue;
      // 'Unity*' also matches UnityPackageManager.exe / Unity.Licensing.Client.exe, so
      // re-check argv[0] the same way the POSIX branch does.
      if (!isUnityEditorCommand(entry.CommandLine)) continue;
      if (!commandLineTargetsProject(entry.CommandLine, normalized)) continue;
      matches.push({ pid: entry.ProcessId, cmd: entry.CommandLine });
    }
    return matches;
  }

  const ps = await execToString('ps', ['-eo', 'pid=,args=']);
  return parseUnityProcesses(ps, normalized, ownUnityPids);
}

function lockFileExists(projectPath) {
  return fs.existsSync(path.join(projectPath, 'Temp', 'UnityLockfile'));
}

function killProcess(pid, force) {
  if (process.platform === 'win32') {
    const args = ['/PID', String(pid), '/T'];
    if (force) args.push('/F');
    return execToString('taskkill.exe', args);
  }
  try {
    process.kill(pid, force ? 'SIGKILL' : 'SIGTERM');
  } catch { /* already gone */ }
  return Promise.resolve('');
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function processStillAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

// Returns { ok: true } to proceed, or { ok: false, reason } to abort.
async function ensureProjectNotOpenInUnity(projectPath) {
  if (!lockFileExists(projectPath)) return { ok: true };

  const foreign = await findForeignUnityProcesses(projectPath);
  // A stale lockfile with no live Editor behind it is harmless - Unity clears it itself.
  if (foreign.length === 0) return { ok: true };

  const { response } = await dialog.showMessageBox(mainWindow, {
    type: 'warning',
    buttons: ['Close Unity and continue', 'Cancel build'],
    defaultId: 1,
    cancelId: 1,
    title: 'Project is open in Unity',
    message: 'This project is currently open in the Unity Editor.',
    detail:
      'Unity can\'t open the same project twice, so the build can\'t run while the Editor ' +
      'has it open.\n\nClosing Unity from here will not save your work first - save anything ' +
      'you need in Unity before continuing.',
  });

  if (response !== 0) {
    return { ok: false, reason: 'Project is open in the Unity Editor and the build was cancelled.' };
  }

  for (const proc of foreign) await killProcess(proc.pid, false);

  // Give the Editor a chance to shut down cleanly (and release the lock) before forcing it.
  for (let waited = 0; waited < 20000; waited += 500) {
    await sleep(500);
    if (!foreign.some((p) => processStillAlive(p.pid))) break;
  }
  for (const proc of foreign) {
    if (processStillAlive(proc.pid)) await killProcess(proc.pid, true);
  }

  // Unity removes Temp/UnityLockfile on exit; if it was killed hard, clear the leftover
  // ourselves so the next launch doesn't trip over it.
  for (let waited = 0; waited < 10000; waited += 500) {
    if (!lockFileExists(projectPath)) break;
    await sleep(500);
  }
  if (lockFileExists(projectPath) && !(await findForeignUnityProcesses(projectPath)).length) {
    try { fs.unlinkSync(path.join(projectPath, 'Temp', 'UnityLockfile')); } catch { /* fine */ }
  }

  return { ok: true };
}

// Unity refuses to open a project that's already locked by another instance of itself
// (Temp/UnityLockfile) - so two Unity launches against the *same* project (e.g. the
// auto-register-mod-folders scan racing a real build, which can otherwise overlap when
// a project gets loaded/selected more than once in quick succession) fail with
// "Multiple Unity instances cannot open the same project" instead of just queueing.
// This serializes every Unity launch per projectPath so that never happens.
const projectUnityLocks = new Map(); // projectPath -> tail promise of the queue
function runUnityBuild(projectPath, unityPath, args) {
  // The already-open check runs INSIDE the queue slot, not before it: checking earlier
  // would race a queued sibling launch that hasn't taken the lock yet.
  const launch = async () => {
    const clear = await ensureProjectNotOpenInUnity(projectPath);
    if (!clear.ok) return { code: -1, error: clear.reason };
    return runUnityBuildProcess(unityPath, args);
  };
  const previous = projectUnityLocks.get(projectPath) || Promise.resolve();
  const run = previous.then(launch, launch);
  projectUnityLocks.set(projectPath, run.catch(() => {}));
  return run;
}

// Streams new lines appended to Unity's -logFile to the renderer as they're written,
// so the build console shows live output instead of only a summary after the fact.
function tailLogFile(logFile, onLine, intervalMs = 300) {
  let position = 0;
  let carry = '';
  const timer = setInterval(() => {
    fs.stat(logFile, (err, stats) => {
      if (err || stats.size <= position) return;
      const stream = fs.createReadStream(logFile, { start: position, encoding: 'utf8' });
      let chunk = '';
      stream.on('data', (d) => { chunk += d; });
      stream.on('end', () => {
        position = stats.size;
        const text = carry + chunk;
        const lines = text.split('\n');
        carry = lines.pop() || '';
        for (const line of lines) {
          if (line.trim()) onLine(line);
        }
      });
    });
  }, intervalMs);
  return () => clearInterval(timer);
}

ipcMain.handle('run-build', async (event, config) => {
  // Normalized the same way as resolveProjectFast() so this always matches the queue
  // key an in-flight auto-register scan for the same project is using.
  const projectPath = path.resolve(config.projectPath);
  const { unityPath, groups, platforms } = config;

  const logDir = path.join(projectPath, 'Tools', 'build-logs');
  fs.mkdirSync(logDir, { recursive: true });

  if (!fs.existsSync(unityPath)) {
    const reason = `Unity executable not found at: ${unityPath}`;
    appendHistoryLog(logDir, `FAILURE  target=(none)  groups=${summarizeGroups(groups)}  reason="${reason}"`);
    return [{ target: null, status: 'failed', error: reason }];
  }

  // The build runs entirely through the bundled Editor script's -executeMethod entry
  // point, so a missing/outdated copy is a hard failure here rather than best-effort.
  const install = ensureExporterScriptInstalled(projectPath);
  if (install.status === 'failed') {
    appendHistoryLog(logDir, `FAILURE  target=(none)  groups=${summarizeGroups(groups)}  reason="${install.error}"`);
    return [{ target: null, status: 'failed', error: install.error }];
  }

  const groupsSummary = summarizeGroups(groups);
  const groupsArg = groups.map((g) => g.name).join('|');
  const versionsArg = groups.map((g) => g.version || '').join('|');
  const zipNamesArg = groups.map((g) => g.zipName || '').join('|');
  const hasVersions = groups.some((g) => g.version && g.version.trim());
  const hasZipNames = groups.some((g) => g.zipName && g.zipName.trim());

  const results = [];

  for (const targetKey of platforms) {
    const target = PLATFORM_TARGETS.find((t) => t.key === targetKey);
    event.sender.send('build-progress', { target: targetKey, status: 'running' });

    const logFile = path.join(logDir, `build-${targetKey}.log`);
    const args = [
      '-batchmode', '-quit', '-nographics',
      '-projectPath', projectPath,
      '-buildTarget', target.buildTargetArg,
      '-executeMethod', 'Editor.AddressablesModExporter.BuildFromCommandLine',
      '-groups', groupsArg,
      '-logFile', logFile,
    ];
    if (hasVersions) args.push('-versions', versionsArg);
    if (hasZipNames) args.push('-zipNames', zipNamesArg);

    try { fs.unlinkSync(logFile); } catch { /* nothing to remove */ }
    const stopTailing = tailLogFile(logFile, (line) => {
      event.sender.send('build-log-line', { target: targetKey, line });
    });

    const { code, error } = await runUnityBuild(projectPath, unityPath, args);
    stopTailing();

    let logContent = '';
    try { logContent = fs.readFileSync(logFile, 'utf8'); } catch { /* no log written yet */ }

    const builtZipPaths = groups.map((g) => expectedZipPath(projectPath, g, target.label));
    const missingZips = builtZipPaths.filter((zipPath) => !fs.existsSync(zipPath));

    const failureMarker = findFailureMarker(logContent);
    let failed = Boolean(error) || Boolean(failureMarker) || missingZips.length > 0;

    let reason = null;
    if (error) reason = `Unity failed to launch: ${error}`;
    else if (failureMarker) reason = `build log contains "${failureMarker}"`;
    else if (missingZips.length > 0) reason = `missing expected output: ${missingZips.join('; ')}`;

    let finalZipPaths = builtZipPaths;
    const outputDir = config.outputDir && config.outputDir.trim();
    const defaultModsDir = path.join(projectPath, 'Mods');
    if (!failed && outputDir && path.resolve(outputDir) !== path.resolve(defaultModsDir)) {
      try {
        finalZipPaths = builtZipPaths.map((src) => {
          const dest = path.join(outputDir, path.basename(src));
          moveFile(src, dest);
          return dest;
        });
      } catch (moveErr) {
        failed = true;
        reason = `built successfully but failed to move output to "${outputDir}": ${moveErr.message}`;
      }
    }

    const result = {
      target: targetKey,
      status: failed ? 'failed' : 'success',
      exitCode: code,
      error: error || null,
      reason,
      missingZips,
      outputPaths: finalZipPaths,
      logTail: logContent.split('\n').slice(-60).join('\n'),
    };
    results.push(result);
    event.sender.send('build-progress', result);

    appendHistoryLog(
      logDir,
      failed
        ? `FAILURE  target=${targetKey}  groups=${groupsSummary}  exitCode=${code}  reason="${reason}"`
        : `SUCCESS  target=${targetKey}  groups=${groupsSummary}  exitCode=${code}`
    );

    if (failed) break;
  }

  return results;
});

// ---------- IPC: GitHub release ----------

// Always releases to this repo - the Unity project the built mods actually come from,
// not the mod-builder tool's own repo. Uses the user's local `gh` CLI (already
// authenticated via `gh auth login`) rather than managing a token in-app.
const GITHUB_RELEASE_REPO = 'MoSim-Modding-Fun/MoSim-Reefscape-Public';

function runGh(args) {
  return new Promise((resolve) => {
    const proc = spawn('gh', args, { windowsHide: false });
    let output = '';
    proc.stdout.on('data', (d) => { output += d; });
    proc.stderr.on('data', (d) => { output += d; });
    proc.on('error', (err) => resolve({ code: -1, output: output + err.message }));
    proc.on('exit', (code) => resolve({ code, output }));
  });
}

ipcMain.handle('create-github-release', async (_event, config) => {
  const { tag, title, notes, files } = config;
  if (!tag || !tag.trim()) return { status: 'failed', output: 'No release tag given.' };
  if (!files || files.length === 0) return { status: 'failed', output: 'No build output to attach.' };

  const args = ['release', 'create', tag.trim(), ...files, '--repo', GITHUB_RELEASE_REPO];
  args.push('--title', title && title.trim() ? title.trim() : tag.trim());
  args.push('--notes', notes && notes.trim() ? notes.trim() : `Built by v25 Mod Builder.`);

  const { code, output } = await runGh(args);
  return { status: code === 0 ? 'success' : 'failed', output };
});
