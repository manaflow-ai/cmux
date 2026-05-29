const { contextBridge, ipcRenderer } = require("electron");

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
  openExternal(url) {
    return ipcRenderer.invoke("open-external", url);
  }
});
