const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  loadSettings: () => ipcRenderer.invoke('load-settings'),
  selectProject: () => ipcRenderer.invoke('select-project'),
  loadProject: (projectPath) => ipcRenderer.invoke('load-project', projectPath),
  browseUnityPath: () => ipcRenderer.invoke('browse-unity-path'),
  browseOutputFolder: () => ipcRenderer.invoke('browse-output-folder'),
  listGroups: (projectPath) => ipcRenderer.invoke('list-groups', projectPath),
  resizeWindowHeight: (height) => ipcRenderer.invoke('resize-window-height', height),
  runBuild: (config) => ipcRenderer.invoke('run-build', config),
  createGitHubRelease: (config) => ipcRenderer.invoke('create-github-release', config),
  onBuildProgress: (callback) => {
    ipcRenderer.on('build-progress', (_event, data) => callback(data));
  },
  onBuildLogLine: (callback) => {
    ipcRenderer.on('build-log-line', (_event, data) => callback(data));
  },
  onProjectScanComplete: (callback) => {
    ipcRenderer.on('project-scan-complete', (_event, data) => callback(data));
  },
});
