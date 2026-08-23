let projectPath = null;
let unityPath = null;
let detectedUnityPath = null;
let outputDir = null; // null = default "<project>/Mods"
let groupsState = {}; // name -> { checked, version, zipName }

let consolePanelsByPlatform = {}; // platformKey -> panel element
let activeConsoleTab = null;
let progressSegments = []; // [{ platform, group, zipName, version, status }], one per (group x platform)

const PAGE_IDS = ['page-project', 'page-groups', 'page-output', 'page-build'];
let currentPage = 0;

// Must match PLATFORM_TARGETS' labels in main.js, which is what the Unity-side
// exporter actually uses to name the zip.
const PLATFORM_LABELS = { win64: 'Windows', osx: 'MacOS', linux64: 'Linux' };

// Synthetic "platform" key for the GitHub release step's own status badge/console tab,
// so it can reuse the exact same badge/console-tab machinery as a real platform build.
const RELEASE_KEY = 'release';
const RELEASE_LABEL = 'Release';

// Must match main.js's GITHUB_RELEASE_REPO - shown to the user so it's clear which
// repo a release actually targets before they click START.
const GITHUB_RELEASE_REPO = 'MoSim-Modding-Fun/MoSim-Reefscape-Public';

const els = {
  selectProjectBtn: document.getElementById('select-project-btn'),
  projectPathField: document.getElementById('project-path-field'),
  projectInfo: document.getElementById('project-info'),
  scanStatus: document.getElementById('scan-status'),
  unityPathField: document.getElementById('unity-path-field'),
  unityInfo: document.getElementById('unity-info'),
  browseUnityBtn: document.getElementById('browse-unity-btn'),
  groupsList: document.getElementById('groups-list'),
  backBtn: document.getElementById('back-btn'),
  nextBtn: document.getElementById('next-btn'),
  buildBtn: document.getElementById('build-btn'),
  closeBtn: document.getElementById('close-btn'),
  buildStatus: document.getElementById('build-status'),
  progressBar: document.getElementById('progress-bar'),
  progressPercent: document.getElementById('progress-percent'),
  consoleTabs: document.getElementById('console-tabs'),
  consolePanels: document.getElementById('console-panels'),
  zipPreview: document.getElementById('zip-preview'),
  outputPathField: document.getElementById('output-path-field'),
  chooseOutputBtn: document.getElementById('choose-output-btn'),
  resetOutputBtn: document.getElementById('reset-output-btn'),
  releaseEnabledCheck: document.getElementById('release-enabled-check'),
  releaseFields: document.getElementById('release-fields'),
  releaseTagField: document.getElementById('release-tag-field'),
  releaseTitleField: document.getElementById('release-title-field'),
  releaseNotesField: document.getElementById('release-notes-field'),
  releaseRepoInfo: document.getElementById('release-repo-info'),
};

els.releaseRepoInfo.textContent = `Releases to ${GITHUB_RELEASE_REPO} via the local gh CLI.`;

// ---------- Wizard paging (Etcher-style: one primary action per step) ----------

function showPage(index) {
  currentPage = index;
  PAGE_IDS.forEach((id, i) => {
    document.getElementById(id).classList.toggle('active', i === index);
  });
  document.querySelectorAll('.step-dots .dot').forEach((dot, i) => {
    dot.classList.toggle('active', i === index);
  });
  updateNav();
}

function updateNav() {
  els.backBtn.disabled = currentPage === 0;

  const projectReady = Boolean(projectPath && unityPath);
  const anyGroupSelected = Object.values(groupsState).some((g) => g.checked);
  const anyPlatformSelected = getSelectedPlatforms().length > 0;
  const buildReady = projectReady && anyGroupSelected && anyPlatformSelected;
  const releaseReady = !els.releaseEnabledCheck.checked || els.releaseTagField.value.trim().length > 0;

  if (currentPage === 0) {
    els.nextBtn.style.display = '';
    els.buildBtn.style.display = 'none';
    els.nextBtn.disabled = !projectReady;
  } else if (currentPage === 1) {
    els.nextBtn.style.display = '';
    els.buildBtn.style.display = 'none';
    els.nextBtn.disabled = !buildReady;
  } else if (currentPage === 2) {
    els.nextBtn.style.display = 'none';
    els.buildBtn.style.display = '';
    els.buildBtn.disabled = !(buildReady && releaseReady);
  } else {
    els.nextBtn.style.display = 'none';
    els.buildBtn.style.display = 'none';
  }

  renderOutputInfo();
  renderZipPreview();
  syncWindowSize();
}

// Asks the main process to fit the window to whatever the active page actually needs,
// so a sparse page (e.g. Project, right after Unity Editor is found) doesn't sit in a
// window sized for a denser one (e.g. Groups with many entries) — and nothing scrolls.
function syncWindowSize() {
  requestAnimationFrame(() => {
    window.api.resizeWindowHeight(document.body.scrollHeight);
  });
}

// Belt-and-suspenders for the manual syncWindowSize() calls scattered at each known
// content-change site: those can still miss a beat when layout settles asynchronously
// (webfont metrics, GTK reflow timing on Linux), which is how the build/console page
// was observed overflowing past the window. A ResizeObserver catches *any* body size
// change, regardless of what caused it.
new ResizeObserver(() => syncWindowSize()).observe(document.body);

els.backBtn.addEventListener('click', () => {
  if (currentPage > 0) showPage(currentPage - 1);
});

els.nextBtn.addEventListener('click', () => {
  if (currentPage < PAGE_IDS.length - 1) showPage(currentPage + 1);
});

els.closeBtn.addEventListener('click', () => window.close());

// ---------- Project / Unity Editor ----------

function renderProjectInfo(info) {
  els.projectPathField.value = info.projectPath || '';
  els.projectPathField.title = info.projectPath || '';
  if (info.error) {
    els.projectInfo.innerHTML = `<span class="error">${info.error}</span>`;
    return;
  }
  els.projectInfo.innerHTML = `Editor version required: <b>${info.unityVersion || 'unknown'}</b> &middot; ${info.groups.length} group(s) found`;
}

function renderUnityInfo() {
  els.unityPathField.value = unityPath || '';
  els.unityPathField.title = unityPath || '';
  if (unityPath) {
    const source = unityPath === detectedUnityPath ? 'auto-detected' : 'manually set';
    els.unityInfo.innerHTML = `<span class="ok">Ready</span> (${source})`;
  } else {
    els.unityInfo.innerHTML = '<span class="error">Not found for this project\'s version &mdash; browse for it.</span>';
  }
}

function setScanning(isScanning) {
  els.scanStatus.style.display = isScanning ? 'flex' : 'none';
  syncWindowSize();
}

// Shared by the SELECT button and by restoring the remembered project on launch.
// Populates everything that's known immediately (no waiting on the background
// auto-register-mod-folders scan main.js may have kicked off - see
// window.api.onProjectScanComplete below, which fills in any groups that scan finds).
function applyProjectInfo(info) {
  if (info.error) {
    renderProjectInfo(info);
    els.unityPathField.value = '';
    els.unityInfo.textContent = '';
    els.groupsList.textContent = 'No project selected yet.';
    projectPath = null;
    setScanning(false);
    updateNav();
    return;
  }

  projectPath = info.projectPath;
  detectedUnityPath = info.detectedUnityPath;
  unityPath = info.detectedUnityPath;

  renderProjectInfo(info);
  renderUnityInfo();
  renderGroups(info.groups);
  setScanning(Boolean(info.scanning));
  updateNav();
}

// Fires once the background scan main.js started for this project finishes. Ignored if
// the user has since selected a different project (matches main.js's own guard).
window.api.onProjectScanComplete((data) => {
  if (data.projectPath !== projectPath) return;
  setScanning(false);

  const currentNames = Object.keys(groupsState);
  const isSame = data.groups.length === currentNames.length && data.groups.every((n) => currentNames.includes(n));
  if (!isSame) {
    renderGroups(data.groups);
    updateNav();
  }
});

// Guards against a slow-resolving project load (e.g. the on-launch reload of the
// remembered project, which can block on an auto-register Unity launch) clobbering a
// manual selection the user made in the meantime - only the most recent request's
// result is ever applied.
let projectRequestId = 0;

async function loadAndApplyProject(loadPromise) {
  const requestId = ++projectRequestId;
  const info = await loadPromise;
  if (requestId !== projectRequestId || !info) return;
  applyProjectInfo(info);
}

els.selectProjectBtn.addEventListener('click', () => {
  loadAndApplyProject(window.api.selectProject());
});

els.browseUnityBtn.addEventListener('click', async () => {
  const chosen = await window.api.browseUnityPath();
  if (!chosen) return;
  unityPath = chosen;
  detectedUnityPath = null;
  renderUnityInfo();
  updateNav();
});

// ---------- Output folder ----------

function renderOutputInfo() {
  els.outputPathField.value = outputDir || '';
  els.outputPathField.title = outputDir || '';
  els.resetOutputBtn.style.display = outputDir ? 'inline-block' : 'none';
}

els.chooseOutputBtn.addEventListener('click', async () => {
  const chosen = await window.api.browseOutputFolder();
  if (!chosen) return;
  outputDir = chosen;
  renderOutputInfo();
  renderZipPreview();
});

els.resetOutputBtn.addEventListener('click', () => {
  outputDir = null;
  renderOutputInfo();
  renderZipPreview();
});

// Mirrors ZipAndCleanup's archive-name logic in AddressablesModExporter.cs:
// "<zipName> [<version>] <PlatformLabel>.zip", zipName defaulting to the group name.
// Destination folder is shown separately in the Output Folder field, not repeated here.
function renderZipPreview() {
  const selectedGroups = Object.entries(groupsState).filter(([, g]) => g.checked);
  const platforms = getSelectedPlatforms();

  if (selectedGroups.length === 0 || platforms.length === 0) {
    els.zipPreview.textContent = 'Select a group and a platform to preview output filenames.';
    return;
  }

  els.zipPreview.innerHTML = '';
  for (const [name, g] of selectedGroups) {
    const zipName = g.zipName.trim() || name;
    const version = g.version.trim();
    for (const platformKey of platforms) {
      const label = PLATFORM_LABELS[platformKey];
      const fileName = version ? `${zipName} ${version} ${label}.zip` : `${zipName} ${label}.zip`;
      const row = document.createElement('div');
      row.className = 'preview-row';
      row.textContent = fileName;
      els.zipPreview.appendChild(row);
    }
  }
}

// ---------- Groups & platforms ----------

function renderGroups(names) {
  groupsState = {};
  els.groupsList.innerHTML = '';

  if (names.length === 0) {
    els.groupsList.textContent = 'No addressable groups found in this project.';
    return;
  }

  for (const name of names) {
    groupsState[name] = { checked: false, version: '', zipName: '' };

    const row = document.createElement('div');
    row.className = 'group-row';

    const mainLabel = document.createElement('label');
    mainLabel.className = 'main';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    mainLabel.appendChild(checkbox);
    mainLabel.appendChild(document.createTextNode(name));
    row.appendChild(mainLabel);

    const fields = document.createElement('div');
    fields.className = 'fields';
    fields.style.display = 'none';

    const versionLabel = document.createElement('label');
    versionLabel.textContent = 'Version (optional)';
    const versionInput = document.createElement('input');
    versionInput.type = 'text';
    versionInput.placeholder = 'none';
    versionLabel.appendChild(versionInput);

    const zipLabel = document.createElement('label');
    zipLabel.textContent = 'Zip name override (optional)';
    const zipInput = document.createElement('input');
    zipInput.type = 'text';
    zipInput.placeholder = name; // grayed-out default: falls back to the group name
    zipLabel.appendChild(zipInput);

    fields.appendChild(versionLabel);
    fields.appendChild(zipLabel);
    row.appendChild(fields);

    checkbox.addEventListener('change', () => {
      groupsState[name].checked = checkbox.checked;
      fields.style.display = checkbox.checked ? 'flex' : 'none';
      updateNav();
    });
    versionInput.addEventListener('input', () => {
      groupsState[name].version = versionInput.value;
      renderZipPreview();
    });
    zipInput.addEventListener('input', () => {
      groupsState[name].zipName = zipInput.value;
      renderZipPreview();
    });

    els.groupsList.appendChild(row);
  }
}

function getSelectedPlatforms() {
  return Array.from(document.querySelectorAll('.platform-check:checked')).map((el) => el.value);
}

document.querySelectorAll('.platform-check').forEach((el) => el.addEventListener('change', updateNav));

// ---------- GitHub release ----------

els.releaseEnabledCheck.addEventListener('change', () => {
  els.releaseFields.style.display = els.releaseEnabledCheck.checked ? 'flex' : 'none';
  updateNav();
});
els.releaseTagField.addEventListener('input', updateNav);

// ---------- Build ----------

els.buildBtn.addEventListener('click', async () => {
  const selectedGroups = Object.entries(groupsState)
    .filter(([, g]) => g.checked)
    .map(([name, g]) => ({ name, version: g.version, zipName: g.zipName }));
  const platforms = getSelectedPlatforms();
  const releaseEnabled = els.releaseEnabledCheck.checked;

  renderConsoleTabs(releaseEnabled ? [...platforms, RELEASE_KEY] : platforms);
  renderProgressSegments(selectedGroups, platforms);

  els.buildStatus.innerHTML = '';
  for (const p of platforms) {
    const row = document.createElement('div');
    row.className = 'platform-row';
    row.innerHTML = `<span>${PLATFORM_LABELS[p]}</span> <span class="badge pending" id="badge-${p}">pending</span>`;
    els.buildStatus.appendChild(row);
  }
  if (releaseEnabled) {
    const row = document.createElement('div');
    row.className = 'platform-row';
    row.innerHTML = `<span>${RELEASE_LABEL}</span> <span class="badge pending" id="badge-${RELEASE_KEY}">pending</span>`;
    els.buildStatus.appendChild(row);
  }

  showPage(PAGE_IDS.length - 1); // jump to the Build page so progress is visible immediately

  const results = await window.api.runBuild({ projectPath, unityPath, groups: selectedGroups, platforms, outputDir });

  const outputPaths = [];
  let allSucceeded = true;
  for (const r of results) {
    appendConsoleLine(r.target, `=== ${r.target} : ${r.status.toUpperCase()} ===`, r.status === 'success' ? 'summary-success' : 'summary-failed');
    if (r.reason) appendConsoleLine(r.target, `Reason: ${r.reason}`, 'summary-failed');
    if (r.status === 'success' && r.outputPaths) {
      for (const p of r.outputPaths) appendConsoleLine(r.target, p, 'summary-success');
      outputPaths.push(...r.outputPaths);
    }
    appendConsoleLine(r.target, 'Full history logged to Tools/build-logs/modbuilder.log in the project.');
    if (r.status !== 'success') allSucceeded = false;
  }

  if (releaseEnabled && allSucceeded && outputPaths.length > 0) {
    await runGitHubRelease(outputPaths);
  } else if (releaseEnabled && !allSucceeded) {
    const badge = document.getElementById(`badge-${RELEASE_KEY}`);
    if (badge) { badge.textContent = 'skipped'; badge.className = 'badge failed'; }
    appendConsoleLine(RELEASE_KEY, 'Skipped: not every platform built successfully.', 'summary-failed');
  }
});

async function runGitHubRelease(files) {
  activateConsoleTab(RELEASE_KEY);
  const badge = document.getElementById(`badge-${RELEASE_KEY}`);
  if (badge) { badge.textContent = 'running'; badge.className = 'badge running'; }
  appendConsoleLine(RELEASE_KEY, `Creating GitHub release on ${GITHUB_RELEASE_REPO}...`);

  const result = await window.api.createGitHubRelease({
    tag: els.releaseTagField.value.trim(),
    title: els.releaseTitleField.value.trim(),
    notes: els.releaseNotesField.value.trim(),
    files,
  });

  for (const line of (result.output || '').split('\n')) {
    if (line.trim()) appendConsoleLine(RELEASE_KEY, line, result.status === 'success' ? 'summary-success' : 'summary-failed');
  }
  if (badge) {
    badge.textContent = result.status;
    badge.className = `badge ${result.status}`;
  }
  appendConsoleLine(
    RELEASE_KEY,
    result.status === 'success' ? `=== RELEASE : SUCCESS ===` : `=== RELEASE : FAILED ===`,
    result.status === 'success' ? 'summary-success' : 'summary-failed'
  );
}

// ---------- Console tabs (one per platform being built) ----------

const BOTTOM_SNAP_PX = 24; // how close to the bottom still counts as "pinned"

function renderConsoleTabs(platforms) {
  els.consoleTabs.innerHTML = '';
  els.consolePanels.innerHTML = '';
  consolePanelsByPlatform = {};

  for (const p of platforms) {
    const tab = document.createElement('button');
    tab.type = 'button';
    tab.className = 'console-tab';
    tab.textContent = p === RELEASE_KEY ? RELEASE_LABEL : PLATFORM_LABELS[p];
    tab.addEventListener('click', () => activateConsoleTab(p));
    els.consoleTabs.appendChild(tab);

    const panel = document.createElement('div');
    panel.className = 'console-panel console';

    const jumpBtn = document.createElement('button');
    jumpBtn.type = 'button';
    jumpBtn.className = 'console-jump-btn';
    jumpBtn.textContent = '↓ Jump to bottom';
    jumpBtn.addEventListener('click', () => scrollConsoleToBottom(panel));
    panel.appendChild(jumpBtn);

    panel.addEventListener('scroll', () => updateConsolePinState(panel));

    consolePanelsByPlatform[p] = panel;
    els.consolePanels.appendChild(panel);
  }

  activateConsoleTab(platforms[0]);
}

function activateConsoleTab(platformKey) {
  activeConsoleTab = platformKey;
  const label = platformKey === RELEASE_KEY ? RELEASE_LABEL : PLATFORM_LABELS[platformKey];
  Array.from(els.consoleTabs.children).forEach((tab) => {
    tab.classList.toggle('active', tab.textContent === label);
  });
  Object.entries(consolePanelsByPlatform).forEach(([p, panel]) => {
    panel.classList.toggle('active', p === platformKey);
  });
  syncWindowSize();
}

function isConsolePinnedToBottom(panel) {
  return panel.scrollHeight - panel.scrollTop - panel.clientHeight <= BOTTOM_SNAP_PX;
}

function updateConsolePinState(panel) {
  panel.classList.toggle('scrolled-up', !isConsolePinnedToBottom(panel));
}

function scrollConsoleToBottom(panel) {
  panel.scrollTop = panel.scrollHeight;
  panel.classList.remove('scrolled-up');
}

function appendConsoleLine(platformKey, text, extraClass) {
  const panel = consolePanelsByPlatform[platformKey];
  if (!panel) return;

  const wasPinned = isConsolePinnedToBottom(panel);

  const row = document.createElement('div');
  row.className = extraClass ? `console-line ${extraClass}` : 'console-line';

  const time = document.createElement('span');
  time.className = 'console-time';
  time.textContent = new Date().toLocaleTimeString('en-US', { hour12: false });
  row.appendChild(time);
  row.appendChild(document.createTextNode(text));

  panel.insertBefore(row, panel.querySelector('.console-jump-btn'));

  // Auto-follow the tail like a live log, but only if the user was already at the
  // bottom - don't yank them back down if they scrolled up to read something.
  if (wasPinned) scrollConsoleToBottom(panel);
  else updateConsolePinState(panel);
}

// ---------- Progress bar: one segment per (group x platform) build unit ----------

function renderProgressSegments(groups, platforms) {
  progressSegments = [];
  for (const p of platforms) {
    for (const g of groups) {
      progressSegments.push({
        platform: p,
        group: g.name,
        zipName: (g.zipName || '').trim() || g.name,
        version: (g.version || '').trim(),
        status: 'pending',
      });
    }
  }
  renderProgressBar();
}

function renderProgressBar() {
  els.progressBar.innerHTML = '';
  for (const seg of progressSegments) {
    const el = document.createElement('div');
    el.className = `progress-segment ${seg.status}`;
    el.title = `${seg.group} — ${PLATFORM_LABELS[seg.platform]}`;
    els.progressBar.appendChild(el);
  }

  const total = progressSegments.length;
  const done = progressSegments.filter((s) => s.status === 'success' || s.status === 'failed').length;
  const pct = total > 0 ? Math.round((done / total) * 100) : 0;
  els.progressPercent.textContent = `${pct}%`;
}

function setSegmentStatus(platformKey, groupName, status) {
  const seg = progressSegments.find((s) => s.platform === platformKey && s.group === groupName);
  if (!seg) return;
  seg.status = status;
  renderProgressBar();
}

// Mirrors ZipAndCleanup's archive-name logic in AddressablesModExporter.cs, same as
// renderZipPreview - used to match a "Zipped mod folder to <path>" log line back to
// the (group, platform) segment it completed.
function expectedFileNameFor(seg) {
  const label = PLATFORM_LABELS[seg.platform];
  return seg.version ? `${seg.zipName} ${seg.version} ${label}.zip` : `${seg.zipName} ${label}.zip`;
}

// Parses AddressablesModExporter.cs's own Debug.Log lines (already streamed to the
// console) to drive per-group progress, without needing any change on the Unity side.
function updateProgressFromLogLine(platformKey, line) {
  const startMatch = line.match(/Building addressables for: (.+?) \(target:/);
  if (startMatch) {
    setSegmentStatus(platformKey, startMatch[1], 'running');
    return;
  }

  const failMatch = line.match(/Addressables build failed for '(.+?)':/);
  if (failMatch) {
    setSegmentStatus(platformKey, failMatch[1], 'failed');
    return;
  }

  const zippedMatch = line.match(/Zipped mod folder to (.+)$/);
  if (zippedMatch) {
    const fileName = zippedMatch[1].trim().split(/[\\/]/).pop();
    const seg = progressSegments.find(
      (s) => s.platform === platformKey && s.status === 'running' && expectedFileNameFor(s) === fileName
    );
    if (seg) { seg.status = 'success'; renderProgressBar(); }
  }
}

window.api.onBuildProgress((data) => {
  const badge = document.getElementById(`badge-${data.target}`);
  if (badge) {
    badge.textContent = data.status;
    badge.className = `badge ${data.status}`;
  }
  // Follow the build: jump the console to whichever platform just started, so the
  // next platform's output is visible as soon as it begins without a manual click.
  if (data.status === 'running') activateConsoleTab(data.target);
});

// Unity's raw -logFile output, streamed live while the build runs (see main.js's
// tailLogFile). This is the actual build console, not just a post-hoc summary.
window.api.onBuildLogLine((data) => {
  appendConsoleLine(data.target, data.line);
  updateProgressFromLogLine(data.target, data.line);
});

// Restore the remembered project, Unity path, and output folder overrides on launch
// (all persisted to settings.json under the OS's per-user app-data directory, so they
// survive across sessions regardless of where the app itself is installed).
window.api.loadSettings().then(async (settings) => {
  if (settings.projectPath) {
    await loadAndApplyProject(window.api.loadProject(settings.projectPath));
  }
  if (settings.unityPathOverride) {
    unityPath = settings.unityPathOverride;
    detectedUnityPath = null;
    renderUnityInfo();
  }
  if (settings.outputDirOverride) {
    outputDir = settings.outputDirOverride;
    renderOutputInfo();
    renderZipPreview();
  }
  updateNav();
});

showPage(0);
