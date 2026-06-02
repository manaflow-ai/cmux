const { contextBridge, ipcRenderer, webUtils } = require("electron");

contextBridge.exposeInMainWorld("cmuxNative", {
  electron: true,
  platform: process.platform,
  onCommand(callback) {
    ipcRenderer.on("cmux-command", (_event, command) => callback(command));
  },
  minimizeWindow() {
    return ipcRenderer.invoke("window:minimize");
  },
  toggleMaximizeWindow() {
    return ipcRenderer.invoke("window:toggle-maximize");
  },
  closeWindow() {
    return ipcRenderer.invoke("window:close");
  },
  isWindowMaximized() {
    return ipcRenderer.invoke("window:is-maximized");
  },
  onWindowState(callback) {
    ipcRenderer.on("window-state", (_event, state) => callback(state));
  },
  beginWindowResize(edge, point) {
    ipcRenderer.send("window:begin-resize", edge, point);
  },
  resizeWindow(point) {
    ipcRenderer.send("window:resize", point);
  },
  endWindowResize() {
    ipcRenderer.send("window:end-resize");
  },
  openExternal(url, profileId = "system") {
    return ipcRenderer.invoke("open-external", url, profileId);
  },
  listBrowserProfiles() {
    return ipcRenderer.invoke("browser:profiles");
  },
  openPath(filePath) {
    return ipcRenderer.invoke("open-path", filePath);
  },
  writeClipboard(text) {
    return ipcRenderer.invoke("clipboard:write-text", text);
  },
  readClipboard() {
    return ipcRenderer.invoke("clipboard:read-text");
  },
  readClipboardImage() {
    return ipcRenderer.invoke("clipboard:read-image-data-url");
  },
  pickBackgroundImage() {
    return ipcRenderer.invoke("background:pick-image");
  },
  filePath(file) {
    return webUtils?.getPathForFile?.(file) || file?.path || "";
  },
  pickWorkspaceFolder() {
    return ipcRenderer.invoke("workspace:pick-folder");
  }
});
