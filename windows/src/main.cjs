const { app, BrowserWindow, Menu, ipcMain, shell, clipboard, dialog } = require("electron");
const { pathToFileURL } = require("node:url");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");
const { formatMessage, t } = require("./i18n.cjs");

let mainWindow = null;
let runtimeChild = null;
let inProcessRuntime = null;
let trustedRendererOrigin = "";
const zoomLockedContents = new WeakSet();

const appRoot = path.resolve(__dirname, "..");
const serverProcessPath = path.join(__dirname, "server-process.cjs");
const clipboardImageDataUrlLimitBytes = 2 * 1024 * 1024;
function log(message) {
  try {
    const logPath = path.join(app.getPath("userData"), "cmux-windows.log");
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, `${new Date().toISOString()} ${message}\n`);
  } catch {
    // Best-effort debug logging.
  }
}

function resetWebContentsZoom(contents) {
  if (!contents || contents.isDestroyed?.()) return;
  try {
    contents.setZoomFactor(1);
    const limits = contents.setVisualZoomLevelLimits?.(1, 1);
    limits?.catch?.((error) => log(`setVisualZoomLevelLimits failed: ${error?.message || error}`));
  } catch (error) {
    log(`reset zoom failed: ${error?.message || error}`);
  }
}

function lockWebContentsZoom(contents) {
  if (!contents || contents.isDestroyed?.()) return;
  resetWebContentsZoom(contents);
  if (zoomLockedContents.has(contents)) return;
  zoomLockedContents.add(contents);
  contents.on("zoom-changed", (event) => {
    event.preventDefault();
    resetWebContentsZoom(contents);
  });
  contents.on("did-finish-load", () => resetWebContentsZoom(contents));
}

async function openExternalSafely(url) {
  if (typeof url !== "string" || !/^https?:\/\//i.test(url)) {
    return { ok: false, error: "unsupported_url" };
  }
  try {
    await shell.openExternal(url);
    return { ok: true };
  } catch (error) {
    log(`open external failed: ${error?.message || error}`);
    return { ok: false, error: "open_external_failed" };
  }
}

function externalWindowOpenHandler({ url }) {
  openExternalSafely(url).then((result) => {
    if (!result.ok) log(`window open denied without external launch: ${result.error}`);
  });
  return { action: "deny" };
}

function hardenWebContents(contents) {
  lockWebContentsZoom(contents);
  if (typeof contents?.setWindowOpenHandler === "function") {
    contents.setWindowOpenHandler(externalWindowOpenHandler);
  }
}

function hardenWebviewPreferences(webPreferences = {}) {
  delete webPreferences.preload;
  delete webPreferences.preloadURL;
  webPreferences.nodeIntegration = false;
  webPreferences.nodeIntegrationInSubFrames = false;
  webPreferences.contextIsolation = true;
  webPreferences.sandbox = true;
  webPreferences.webSecurity = true;
  webPreferences.allowRunningInsecureContent = false;
}

function isAllowedWebviewInitialUrl(url) {
  if (!url) return true;
  return /^https?:\/\//i.test(url) || url === "about:blank";
}

function attachWebviewHardening(contents) {
  contents.on("will-attach-webview", (event, webPreferences, params = {}) => {
    hardenWebviewPreferences(webPreferences);
    if (!isAllowedWebviewInitialUrl(params.src || "")) {
      event.preventDefault();
      log(`blocked webview attach url=${params.src || ""}`);
    }
  });
  contents.on("did-attach-webview", (_event, webContents) => {
    hardenWebContents(webContents);
  });
}

function isTrustedIpcEvent(event) {
  if (!event || !mainWindow || event.sender !== mainWindow.webContents || !trustedRendererOrigin) return false;
  const frameUrl = event.senderFrame?.url || event.sender.getURL?.() || "";
  try {
    return new URL(frameUrl).origin === trustedRendererOrigin;
  } catch {
    return false;
  }
}

function trustedIpcHandler(handler, fallback) {
  return async (event, ...args) => {
    if (!isTrustedIpcEvent(event)) {
      log(`blocked ipc ${event?.senderFrame?.url || "unknown"}`);
      return typeof fallback === "function" ? fallback() : fallback;
    }
    return handler(event, ...args);
  };
}

function firstExistingPath(paths) {
  return paths.find((candidate) => candidate && fs.existsSync(candidate)) || "";
}

function browserInstallSources() {
  const programFiles = process.env.ProgramFiles || "C:\\Program Files";
  const programFilesX86 = process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)";
  const localAppData = process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local");
  return [
    {
      id: "chrome",
      label: "Chrome",
      executablePaths: [
        path.join(programFiles, "Google", "Chrome", "Application", "chrome.exe"),
        path.join(programFilesX86, "Google", "Chrome", "Application", "chrome.exe"),
        path.join(localAppData, "Google", "Chrome", "Application", "chrome.exe")
      ],
      userDataDir: path.join(localAppData, "Google", "Chrome", "User Data")
    },
    {
      id: "edge",
      label: "Edge",
      executablePaths: [
        path.join(programFiles, "Microsoft", "Edge", "Application", "msedge.exe"),
        path.join(programFilesX86, "Microsoft", "Edge", "Application", "msedge.exe"),
        path.join(localAppData, "Microsoft", "Edge", "Application", "msedge.exe")
      ],
      userDataDir: path.join(localAppData, "Microsoft", "Edge", "User Data")
    },
    {
      id: "brave",
      label: "Brave",
      executablePaths: [
        path.join(programFiles, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
        path.join(programFilesX86, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
        path.join(localAppData, "BraveSoftware", "Brave-Browser", "Application", "brave.exe")
      ],
      userDataDir: path.join(localAppData, "BraveSoftware", "Brave-Browser", "User Data")
    }
  ];
}

function browserProfileName(userDataDir, profileDirectory) {
  const fallback = profileDirectory === "Default" ? "Default" : profileDirectory.replace(/^Profile\s+/i, "Profile ");
  try {
    const preferencesPath = path.join(userDataDir, profileDirectory, "Preferences");
    const preferences = JSON.parse(fs.readFileSync(preferencesPath, "utf8"));
    const name = String(preferences?.profile?.name || "").trim();
    return name || fallback;
  } catch {
    return fallback;
  }
}

function browserProfileDirectories(userDataDir) {
  try {
    const entries = fs.readdirSync(userDataDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .filter((name) => name === "Default" || /^Profile \d+$/i.test(name));
    return entries.sort((left, right) => {
      if (left === "Default") return -1;
      if (right === "Default") return 1;
      return left.localeCompare(right, undefined, { numeric: true });
    });
  } catch {
    return [];
  }
}

function detectedBrowserProfiles() {
  const profiles = [{
    id: "system",
    label: t("browser.systemDefault"),
    browser: t("browser.system"),
    profileName: t("browser.defaultProfile"),
    profileDirectory: "",
    executable: ""
  }];
  for (const source of browserInstallSources()) {
    const executable = firstExistingPath(source.executablePaths);
    if (!executable) continue;
    const directories = browserProfileDirectories(source.userDataDir);
    const profileDirectories = directories.length ? directories : ["Default"];
    for (const profileDirectory of profileDirectories) {
      const profileName = browserProfileName(source.userDataDir, profileDirectory);
      profiles.push({
        id: `${source.id}:${profileDirectory}`,
        label: formatMessage("browser.profileLabel", { browser: source.label, profile: profileName }),
        browser: source.label,
        profileName,
        profileDirectory,
        executable
      });
    }
  }
  return profiles;
}

function publicBrowserProfiles() {
  return detectedBrowserProfiles().map(({ executable, ...profile }) => profile);
}

async function openUrlInBrowserProfile(url, profileId = "system") {
  if (typeof url !== "string" || !/^https?:\/\//i.test(url)) {
    return { ok: false, error: "unsupported_url" };
  }
  const profiles = detectedBrowserProfiles();
  const profile = profiles.find((candidate) => candidate.id === profileId) || profiles[0];
  if (!profile || profile.id === "system" || !profile.executable) {
    const result = await openExternalSafely(url);
    return { ok: result.ok, profileId: "system", error: result.error };
  }
  try {
    const child = spawn(profile.executable, [`--profile-directory=${profile.profileDirectory}`, url], {
      detached: true,
      stdio: "ignore",
      windowsHide: false
    });
    child.unref();
    return { ok: true, profileId: profile.id };
  } catch (error) {
    log(`profile browser launch failed: ${error?.message || error}`);
    const result = await openExternalSafely(url);
    return { ok: result.ok, profileId: "system", error: result.ok ? "profile_launch_failed" : result.error };
  }
}

function spawnRuntimeProcess() {
  return new Promise((resolve, reject) => {
    const startupTimeoutMs = Math.max(1000, Number(process.env.CMUX_RUNTIME_STARTUP_TIMEOUT || 15000));
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
    let startupTimer = null;

    const cleanup = () => {
      if (startupTimer) {
        clearTimeout(startupTimer);
        startupTimer = null;
      }
      readyReader.close();
      child.removeListener("error", onError);
      child.removeListener("exit", onExit);
    };

    const settleReject = (error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    };

    const readyReader = readline.createInterface({ input: child.stdout });
    readyReader.on("line", (line) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      try {
        const message = JSON.parse(trimmed);
        if (message.type === "ready") {
          settled = true;
          cleanup();
          runtimeChild = child;
          resolve({ url: message.url, port: message.port, pipeName: message.pipeName, launchToken: message.launchToken });
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

    const onError = (error) => settleReject(error);

    const onExit = (code, signal) => {
      settleReject(new Error(`runtime exited before ready: code=${code} signal=${signal} ${stderr.join("")}`));
    };

    child.on("error", onError);
    child.on("exit", onExit);
    startupTimer = setTimeout(() => {
      if (child && !child.killed) child.kill();
      settleReject(new Error("runtime startup timed out"));
    }, startupTimeoutMs);
  });
}

async function startRuntime() {
  try {
    return await spawnRuntimeProcess();
  } catch (error) {
    log(`runtime process unavailable: ${error?.message || error}`);
    console.warn("Falling back to in-process runtime.");
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
      label: t("menu.file"),
      submenu: [
        { label: t("menu.newWorkspace"), accelerator: "Ctrl+N", click: () => mainWindow?.webContents.send("cmux-command", "workspace.new") },
        { label: t("menu.renameWorkspace"), click: () => mainWindow?.webContents.send("cmux-command", "workspace.rename") },
        { label: t("menu.workspaceBlueprints"), click: () => mainWindow?.webContents.send("cmux-command", "settings.blueprints") },
        { label: t("menu.newTerminal"), accelerator: "Ctrl+T", click: () => mainWindow?.webContents.send("cmux-command", "terminal.new") },
        { label: t("menu.runCommand"), accelerator: "Ctrl+Shift+Enter", click: () => mainWindow?.webContents.send("cmux-command", "terminal.runCommand") },
        { label: t("menu.reopenClosedPane"), accelerator: "Ctrl+Shift+T", click: () => mainWindow?.webContents.send("cmux-command", "terminal.reopenClosed") },
        { label: t("menu.copyTerminalSelection"), accelerator: "Ctrl+Shift+C", click: () => mainWindow?.webContents.send("cmux-command", "terminal.copySelection") },
        { label: t("menu.pasteClipboard"), accelerator: "Ctrl+Shift+V", click: () => mainWindow?.webContents.send("cmux-command", "terminal.pasteClipboard") },
        { label: t("menu.restartTerminal"), accelerator: "Ctrl+Shift+R", click: () => mainWindow?.webContents.send("cmux-command", "terminal.restart") },
        { label: t("menu.closeActivePane"), accelerator: "Ctrl+W", click: () => mainWindow?.webContents.send("cmux-command", "terminal.close") },
        { label: t("menu.openBrowser"), accelerator: "Ctrl+Shift+L", click: () => mainWindow?.webContents.send("cmux-command", "browser.new") },
        { type: "separator" },
        { label: t("menu.settings"), accelerator: "Ctrl+,", click: () => mainWindow?.webContents.send("cmux-command", "settings.open") },
        { label: t("menu.colorSettings"), click: () => mainWindow?.webContents.send("cmux-command", "settings.colors") },
        { label: t("menu.backgroundSettings"), click: () => mainWindow?.webContents.send("cmux-command", "settings.backgrounds") },
        { label: t("menu.settingsProfiles"), click: () => mainWindow?.webContents.send("cmux-command", "settings.profiles") },
        { label: t("menu.commandSnippets"), click: () => mainWindow?.webContents.send("cmux-command", "settings.commands") },
        { type: "separator" },
        { role: "quit" }
      ]
    },
    {
      label: t("menu.edit"),
      submenu: [
        { label: t("menu.findTerminal"), accelerator: "Ctrl+F", click: () => mainWindow?.webContents.send("cmux-command", "terminal.find") },
        { label: t("menu.findNext"), accelerator: "F3", click: () => mainWindow?.webContents.send("cmux-command", "terminal.findNext") },
        { label: t("menu.findPrevious"), accelerator: "Shift+F3", click: () => mainWindow?.webContents.send("cmux-command", "terminal.findPrevious") },
        { type: "separator" },
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
      label: t("menu.view"),
      submenu: [
        { label: t("menu.commandPalette"), accelerator: "Ctrl+Shift+P", click: () => mainWindow?.webContents.send("cmux-command", "palette.toggle") },
        { label: t("menu.toggleSidebar"), accelerator: "Ctrl+B", click: () => mainWindow?.webContents.send("cmux-command", "sidebar.toggle") },
        { type: "separator" },
        { label: t("menu.nextPane"), accelerator: "Ctrl+Tab", click: () => mainWindow?.webContents.send("cmux-command", "terminal.nextPane") },
        { label: t("menu.previousPane"), accelerator: "Ctrl+Shift+Tab", click: () => mainWindow?.webContents.send("cmux-command", "terminal.previousPane") },
        { label: t("menu.lastPane"), accelerator: "Ctrl+Shift+Backspace", click: () => mainWindow?.webContents.send("cmux-command", "terminal.lastPane") },
        { label: t("menu.nextWorkspace"), accelerator: "Ctrl+PageDown", click: () => mainWindow?.webContents.send("cmux-command", "workspace.next") },
        { label: t("menu.previousWorkspace"), accelerator: "Ctrl+PageUp", click: () => mainWindow?.webContents.send("cmux-command", "workspace.previous") },
        { label: t("menu.lastWorkspace"), accelerator: "Ctrl+Alt+Backspace", click: () => mainWindow?.webContents.send("cmux-command", "workspace.last") },
        { type: "separator" },
        { label: t("menu.tunePerformance"), click: () => mainWindow?.webContents.send("cmux-command", "settings.tunePerformance") },
        { label: t("menu.performanceSettings"), click: () => mainWindow?.webContents.send("cmux-command", "settings.performance") },
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
    minWidth: 480,
    minHeight: 400,
    title: "cmux Windows",
    backgroundColor: "#111316",
    frame: false,
    thickFrame: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
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
  attachWebviewHardening(mainWindow.webContents);
  mainWindow.webContents.on("render-process-gone", (_event, details) => {
    log(`render-process-gone ${JSON.stringify(details)}`);
  });
  hardenWebContents(mainWindow.webContents);
  mainWindow.on("maximize", () => mainWindow?.webContents.send("window-state", { maximized: true }));
  mainWindow.on("unmaximize", () => mainWindow?.webContents.send("window-state", { maximized: false }));
  const launchUrl = new URL(runtime.url);
  if (runtime.launchToken) launchUrl.searchParams.set("token", runtime.launchToken);
  trustedRendererOrigin = launchUrl.origin;
  await mainWindow.loadURL(launchUrl.href);
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
  ipcMain.handle("window:minimize", trustedIpcHandler(() => {
    mainWindow?.minimize();
    return true;
  }, false));
  ipcMain.handle("window:toggle-maximize", trustedIpcHandler(() => {
    if (!mainWindow) return false;
    if (mainWindow.isMaximized()) {
      mainWindow.unmaximize();
    } else {
      mainWindow.maximize();
    }
    return mainWindow.isMaximized();
  }, false));
  ipcMain.handle("window:close", trustedIpcHandler(() => {
    mainWindow?.close();
    return true;
  }, false));
  ipcMain.handle("window:is-maximized", trustedIpcHandler(() => Boolean(mainWindow?.isMaximized()), false));
  ipcMain.handle("open-external", trustedIpcHandler((_event, url, profileId = "system") => openUrlInBrowserProfile(url, profileId), { ok: false, error: "forbidden" }));
  ipcMain.handle("browser:profiles", trustedIpcHandler(() => publicBrowserProfiles(), []));
  ipcMain.handle("open-path", trustedIpcHandler(async (_event, filePath) => {
    if (typeof filePath !== "string" || !filePath.trim()) return { ok: false, error: "missing path" };
    const targetPath = path.resolve(filePath);
    if (!fs.existsSync(targetPath)) return { ok: false, error: "path not found" };
    const error = await shell.openPath(targetPath);
    return { ok: !error, error };
  }, { ok: false, error: "forbidden" }));
  ipcMain.handle("clipboard:write-text", trustedIpcHandler((_event, text) => {
    clipboard.writeText(String(text || ""));
    return true;
  }, false));
  ipcMain.handle("clipboard:read-text", trustedIpcHandler(() => clipboard.readText(), ""));
  ipcMain.handle("clipboard:read-image-data-url", trustedIpcHandler(() => {
    const image = clipboard.readImage();
    if (!image || image.isEmpty()) return { ok: false, error: "empty" };
    const dataUrl = image.toDataURL();
    if (Buffer.byteLength(dataUrl, "utf8") > clipboardImageDataUrlLimitBytes) {
      return { ok: false, error: "too_large" };
    }
    return { ok: true, dataUrl };
  }, { ok: false, error: "forbidden" }));
  ipcMain.handle("background:pick-image", trustedIpcHandler(async () => {
    if (!mainWindow) return "";
    const result = await dialog.showOpenDialog(mainWindow, {
      title: t("dialog.chooseBackground"),
      properties: ["openFile"],
      filters: [
        { name: t("dialog.images"), extensions: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "avif", "svg"] }
      ]
    });
    const filePath = result.canceled ? "" : result.filePaths[0];
    return filePath ? pathToFileURL(filePath).href : "";
  }, ""));
  ipcMain.handle("workspace:pick-folder", trustedIpcHandler(async () => {
    if (!mainWindow) return "";
    const result = await dialog.showOpenDialog(mainWindow, {
      title: t("dialog.chooseWorkspaceFolder"),
      properties: ["openDirectory", "createDirectory"]
    });
    return result.canceled ? "" : result.filePaths[0] || "";
  }, ""));

  app.on("second-instance", () => {
    if (!mainWindow) return;
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  });

  app.on("web-contents-created", (_event, contents) => hardenWebContents(contents));

  app.whenReady().then(createWindow);
  app.on("window-all-closed", () => {
    if (process.platform !== "darwin") app.quit();
  });
  app.on("before-quit", stopRuntime);
}
