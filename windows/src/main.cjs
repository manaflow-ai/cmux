const { app, BrowserWindow, Menu, ipcMain, shell, clipboard, dialog } = require("electron");
const { pathToFileURL } = require("node:url");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

let mainWindow = null;
let runtimeChild = null;
let inProcessRuntime = null;

const appRoot = path.resolve(__dirname, "..");
const serverProcessPath = path.join(__dirname, "server-process.cjs");
function log(message) {
  try {
    const logPath = path.join(app.getPath("userData"), "cmux-windows.log");
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, `${new Date().toISOString()} ${message}\n`);
  } catch {
    // Best-effort debug logging.
  }
}

function spawnRuntimeProcess() {
  return new Promise((resolve, reject) => {
    const nodeExe = process.env.CMUX_WINDOWS_NODE || "node";
    const child = spawn(nodeExe, [serverProcessPath], {
      cwd: appRoot,
      env: {
        ...process.env,
        CMUX_WINDOWS_STATIC_DIR: path.join(appRoot, "renderer")
      },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true
    });

    let settled = false;
    const stderr = [];

    const readyReader = readline.createInterface({ input: child.stdout });
    readyReader.on("line", (line) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      try {
        const message = JSON.parse(trimmed);
        if (message.type === "ready") {
          settled = true;
          runtimeChild = child;
          resolve({ url: message.url, port: message.port, pipeName: message.pipeName });
        }
      } catch {
        console.log(`[cmux-windows-runtime] ${trimmed}`);
      }
    });

    child.stderr.on("data", (chunk) => {
      const text = chunk.toString();
      stderr.push(text);
      console.error(`[cmux-windows-runtime] ${text.trimEnd()}`);
    });

    child.on("error", (error) => {
      if (!settled) reject(error);
    });

    child.on("exit", (code, signal) => {
      if (!settled) {
        reject(new Error(`runtime exited before ready: code=${code} signal=${signal} ${stderr.join("")}`));
      }
    });
  });
}

async function startRuntime() {
  try {
    return await spawnRuntimeProcess();
  } catch (error) {
    console.warn(`Falling back to in-process runtime: ${error.message}`);
    const { createCmuxWindowsRuntime } = require("./server.cjs");
    inProcessRuntime = createCmuxWindowsRuntime({
      staticDir: path.join(appRoot, "renderer")
    });
    return await inProcessRuntime.listen();
  }
}

function buildMenu() {
  return Menu.buildFromTemplate([
    {
      label: "File",
      submenu: [
        { label: "New Workspace", accelerator: "Ctrl+N", click: () => mainWindow?.webContents.send("cmux-command", "workspace.new") },
        { label: "Rename Workspace", click: () => mainWindow?.webContents.send("cmux-command", "workspace.rename") },
        { label: "New Terminal", accelerator: "Ctrl+T", click: () => mainWindow?.webContents.send("cmux-command", "terminal.new") },
        { label: "Reopen Closed Pane", accelerator: "Ctrl+Shift+T", click: () => mainWindow?.webContents.send("cmux-command", "terminal.reopenClosed") },
        { label: "Copy Terminal Selection", accelerator: "Ctrl+Shift+C", click: () => mainWindow?.webContents.send("cmux-command", "terminal.copySelection") },
        { label: "Paste Clipboard to Terminal", accelerator: "Ctrl+Shift+V", click: () => mainWindow?.webContents.send("cmux-command", "terminal.pasteClipboard") },
        { label: "Restart Active Terminal", accelerator: "Ctrl+Shift+R", click: () => mainWindow?.webContents.send("cmux-command", "terminal.restart") },
        { label: "Close Active Pane", accelerator: "Ctrl+W", click: () => mainWindow?.webContents.send("cmux-command", "terminal.close") },
        { label: "Open Browser", accelerator: "Ctrl+Shift+L", click: () => mainWindow?.webContents.send("cmux-command", "browser.new") },
        { type: "separator" },
        { label: "Settings", accelerator: "Ctrl+,", click: () => mainWindow?.webContents.send("cmux-command", "settings.open") },
        { type: "separator" },
        { role: "quit" }
      ]
    },
    {
      label: "Edit",
      submenu: [
        { role: "undo" },
        { role: "redo" },
        { type: "separator" },
        { role: "cut" },
        { role: "copy" },
        { role: "paste" },
        { role: "selectAll" }
      ]
    },
    {
      label: "View",
      submenu: [
        { label: "Command Palette", accelerator: "Ctrl+Shift+P", click: () => mainWindow?.webContents.send("cmux-command", "palette.toggle") },
        { label: "Toggle Sidebar", accelerator: "Ctrl+B", click: () => mainWindow?.webContents.send("cmux-command", "sidebar.toggle") },
        { type: "separator" },
        { role: "reload" },
        { role: "toggleDevTools" }
      ]
    }
  ]);
}

async function createWindow() {
  const runtime = await startRuntime();
  Menu.setApplicationMenu(buildMenu());

  mainWindow = new BrowserWindow({
    width: 1320,
    height: 860,
    minWidth: 940,
    minHeight: 620,
    title: "cmux Windows",
    backgroundColor: "#111316",
    frame: false,
    thickFrame: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      webviewTag: true
    }
  });

  mainWindow.once("ready-to-show", () => mainWindow.show());
  mainWindow.webContents.on("console-message", (_event, level, message, line, sourceId) => {
    log(`renderer console level=${level} ${sourceId}:${line} ${message}`);
  });
  mainWindow.webContents.on("did-fail-load", (_event, errorCode, errorDescription, validatedURL) => {
    log(`did-fail-load code=${errorCode} description=${errorDescription} url=${validatedURL}`);
  });
  mainWindow.webContents.on("render-process-gone", (_event, details) => {
    log(`render-process-gone ${JSON.stringify(details)}`);
  });
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: "deny" };
  });
  mainWindow.on("maximize", () => mainWindow?.webContents.send("window-state", { maximized: true }));
  mainWindow.on("unmaximize", () => mainWindow?.webContents.send("window-state", { maximized: false }));
  await mainWindow.loadURL(runtime.url);
}

function stopRuntime() {
  if (runtimeChild && !runtimeChild.killed) {
    runtimeChild.kill();
    runtimeChild = null;
  }
  if (inProcessRuntime) {
    inProcessRuntime.close();
    inProcessRuntime = null;
  }
}

const hasLock = app.requestSingleInstanceLock();
if (!hasLock) {
  app.quit();
} else {
  ipcMain.handle("window:minimize", () => mainWindow?.minimize());
  ipcMain.handle("window:toggle-maximize", () => {
    if (!mainWindow) return false;
    if (mainWindow.isMaximized()) {
      mainWindow.unmaximize();
    } else {
      mainWindow.maximize();
    }
    return mainWindow.isMaximized();
  });
  ipcMain.handle("window:close", () => mainWindow?.close());
  ipcMain.handle("window:is-maximized", () => Boolean(mainWindow?.isMaximized()));
  ipcMain.handle("open-external", (_event, url) => {
    if (typeof url === "string" && /^https?:\/\//i.test(url)) {
      return shell.openExternal(url);
    }
    return false;
  });
  ipcMain.handle("open-path", async (_event, filePath) => {
    if (typeof filePath !== "string" || !filePath.trim()) return { ok: false, error: "missing path" };
    const targetPath = path.resolve(filePath);
    if (!fs.existsSync(targetPath)) return { ok: false, error: "path not found" };
    const error = await shell.openPath(targetPath);
    return { ok: !error, error };
  });
  ipcMain.handle("clipboard:write-text", (_event, text) => {
    clipboard.writeText(String(text || ""));
    return true;
  });
  ipcMain.handle("clipboard:read-text", () => clipboard.readText());
  ipcMain.handle("background:pick-image", async () => {
    if (!mainWindow) return "";
    const result = await dialog.showOpenDialog(mainWindow, {
      title: "Choose background image",
      properties: ["openFile"],
      filters: [
        { name: "Images", extensions: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "avif"] }
      ]
    });
    const filePath = result.canceled ? "" : result.filePaths[0];
    return filePath ? pathToFileURL(filePath).href : "";
  });
  ipcMain.handle("workspace:pick-folder", async () => {
    if (!mainWindow) return "";
    const result = await dialog.showOpenDialog(mainWindow, {
      title: "Choose workspace folder",
      properties: ["openDirectory", "createDirectory"]
    });
    return result.canceled ? "" : result.filePaths[0] || "";
  });

  app.on("second-instance", () => {
    if (!mainWindow) return;
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  });

  app.whenReady().then(createWindow);
  app.on("window-all-closed", () => {
    if (process.platform !== "darwin") app.quit();
  });
  app.on("before-quit", stopRuntime);
}
