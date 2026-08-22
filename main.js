const { app, BrowserWindow, ipcMain, dialog, screen } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');

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
    icon: path.join(__dirname, 'build', process.platform === 'win32' ? 'icon.ico' : 'icon.png'),
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
]);

function listAddressableGroups(projectPath) {
  const groupsDir = path.join(projectPath, 'Assets', 'AddressableAssetsData', 'AssetGroups');
  if (!fs.existsSync(groupsDir)) return [];

  const names = [];
  for (const entry of fs.readdirSync(groupsDir, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith('.asset')) continue;
    const content = fs.readFileSync(path.join(groupsDir, entry.name), 'utf8');
    const match = content.match(/m_GroupName:\s*(.+)/);
    if (!match) continue;
    const name = match[1].trim();
    if (RESERVED_GROUP_NAMES.has(name)) continue;
    names.push(name);
  }
  return names.sort();
}

// ---------- IPC: settings & project selection ----------

ipcMain.handle('load-settings', () => loadSettings());

// Shared by the dialog-driven picker and by restoring the last-used project on
// launch, so "select a project" and "reopen the remembered one" can't drift apart.
function resolveProject(projectPath) {
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

  const groups = listAddressableGroups(projectPath);
  const detectedUnityPath = unityVersion ? detectUnity(unityVersion) : null;

  const settings = loadSettings();
  settings.projectPath = projectPath;
  saveSettings(settings);

  return { projectPath, unityVersion, groups, detectedUnityPath };
}

ipcMain.handle('select-project', async () => {
  const result = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory'] });
  if (result.canceled || result.filePaths.length === 0) return null;
  return resolveProject(result.filePaths[0]);
});

// Restores the project remembered from the last session (settings.json, in the OS's
// per-user app-data directory — see settingsPath() — so it survives an installed,
// read-only Program Files-style deployment, not just a dev checkout).
ipcMain.handle('load-project', (_event, projectPath) => {
  if (!fs.existsSync(projectPath)) {
    return { error: `Remembered project "${projectPath}" no longer exists.` };
  }
  return resolveProject(projectPath);
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

const PLATFORM_TARGETS = [
  { key: 'win64', label: 'Windows' },
  { key: 'osx', label: 'MacOS' },
  { key: 'linux64', label: 'Linux' },
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

function runUnityBuild(unityPath, args) {
  return new Promise((resolve) => {
    const proc = spawn(unityPath, args, { windowsHide: false });
    proc.on('error', (err) => resolve({ code: -1, error: err.message }));
    proc.on('exit', (code) => resolve({ code }));
  });
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
  const { projectPath, unityPath, groups, platforms } = config;

  const logDir = path.join(projectPath, 'Tools', 'build-logs');
  fs.mkdirSync(logDir, { recursive: true });

  if (!fs.existsSync(unityPath)) {
    const reason = `Unity executable not found at: ${unityPath}`;
    appendHistoryLog(logDir, `FAILURE  target=(none)  groups=${summarizeGroups(groups)}  reason="${reason}"`);
    return [{ target: null, status: 'failed', error: reason }];
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
      '-buildTarget', targetKey,
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

    const { code, error } = await runUnityBuild(unityPath, args);
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
