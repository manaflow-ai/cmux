const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { fileURLToPath } = require("node:url");
const { spawn, spawnSync } = require("node:child_process");
const { WebSocket, WebSocketServer } = require("ws");

let pty = null;
try {
  pty = require("node-pty");
} catch {
  pty = null;
}

const defaultPipeName = process.platform === "win32"
  ? "\\\\.\\pipe\\cmux-windows"
  : path.join(os.tmpdir(), "cmux-windows.sock");
const defaultBrowserHomeUrl = "https://www.google.com";

const workspaceColors = [
  "oklch(62% 0.22 255)",
  "oklch(70% 0.16 145)",
  "oklch(76% 0.15 82)",
  "oklch(68% 0.18 330)",
  "oklch(70% 0.14 195)",
  "oklch(64% 0.17 28)",
  "oklch(74% 0.18 305)",
  "oklch(72% 0.17 230)",
  "oklch(74% 0.12 35)",
  "oklch(80% 0.1 115)",
  "oklch(66% 0.13 175)",
  "oklch(86% 0.11 70)"
];

const localImageContentTypes = new Map([
  [".avif", "image/avif"],
  [".bmp", "image/bmp"],
  [".gif", "image/gif"],
  [".jpeg", "image/jpeg"],
  [".jpg", "image/jpeg"],
  [".png", "image/png"],
  [".webp", "image/webp"]
]);

function isSafeColorValue(value) {
  const color = String(value || "").trim();
  return workspaceColors.includes(color) || /^#[0-9a-f]{6}$/i.test(color);
}

function id(prefix) {
  return `${prefix}_${crypto.randomUUID()}`;
}

function appDataRoot() {
  const root = process.env.APPDATA || path.join(os.homedir(), ".config");
  return path.join(root, "cmux-windows");
}

function writeJSON(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body)
  });
  response.end(body);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function localImagePathFromUrl(value) {
  try {
    const parsed = new URL(String(value || ""));
    if (parsed.protocol !== "file:") return "";
    const filePath = path.resolve(fileURLToPath(parsed));
    const ext = path.extname(filePath).toLowerCase();
    if (!localImageContentTypes.has(ext)) return "";
    const stat = fs.statSync(filePath);
    return stat.isFile() ? filePath : "";
  } catch {
    return "";
  }
}

const shellProfileIds = new Set(["auto", "pwsh", "powershell", "cmd", "wsl", "git-bash", "custom"]);
const executableExistsCache = new Map();
const resolvedShellCache = new Map();

function sanitizeShellProfile(value) {
  const profile = String(value || "auto").trim();
  return shellProfileIds.has(profile) ? profile : "auto";
}

function sanitizeShellPath(value) {
  return String(value || "").trim().slice(0, 512);
}

function sanitizeTerminalFontSize(value, fallback = 0) {
  const size = Number(value);
  if (!Number.isFinite(size) || size <= 0) return fallback;
  return Math.min(22, Math.max(10, Math.round(size)));
}

function sanitizeDirectoryPath(value, fallback = process.cwd()) {
  const raw = String(value || "").trim();
  if (!raw) return fallback;
  const resolved = path.resolve(raw);
  try {
    return fs.existsSync(resolved) && fs.statSync(resolved).isDirectory()
      ? resolved
      : fallback;
  } catch {
    return fallback;
  }
}

function executableExists(candidate) {
  if (!candidate) return false;
  const cacheKey = process.platform === "win32" ? candidate.toLowerCase() : candidate;
  if (executableExistsCache.has(cacheKey)) return executableExistsCache.get(cacheKey);
  let exists = false;
  if (candidate.includes("\\") || candidate.includes("/") || path.isAbsolute(candidate)) {
    exists = fs.existsSync(candidate);
  } else {
    const probe = process.platform === "win32"
      ? spawnSync("where.exe", [candidate], { stdio: "ignore", windowsHide: true })
      : spawnSync("command", ["-v", candidate], { shell: true, stdio: "ignore" });
    exists = probe.status === 0;
  }
  executableExistsCache.set(cacheKey, exists);
  return exists;
}

function shellCandidates(profile, customShell) {
  if (process.platform !== "win32") return [process.env.SHELL || "/bin/sh", "/bin/bash", "/bin/sh"];
  if (profile === "custom") return [customShell, "pwsh.exe", "powershell.exe", "cmd.exe"];
  if (profile === "pwsh") return ["pwsh.exe", "powershell.exe", "cmd.exe"];
  if (profile === "powershell") return ["powershell.exe", "pwsh.exe", "cmd.exe"];
  if (profile === "cmd") return ["cmd.exe", "powershell.exe"];
  if (profile === "wsl") return ["wsl.exe", "pwsh.exe", "powershell.exe", "cmd.exe"];
  if (profile === "git-bash") {
    return [
      path.join(process.env.ProgramFiles || "C:\\Program Files", "Git", "bin", "bash.exe"),
      path.join(process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", "Git", "bin", "bash.exe"),
      "bash.exe",
      "pwsh.exe",
      "powershell.exe",
      "cmd.exe"
    ];
  }
  if (process.env.CMUX_WINDOWS_SHELL) return [process.env.CMUX_WINDOWS_SHELL, "pwsh.exe", "powershell.exe", "cmd.exe"];
  return ["pwsh.exe", "powershell.exe", "cmd.exe"];
}

function resolveShell(profile = "auto", customShell = "") {
  const sanitizedProfile = sanitizeShellProfile(profile);
  const sanitizedCustomShell = sanitizeShellPath(customShell);
  const cacheKey = `${sanitizedProfile}\0${sanitizedCustomShell}`;
  if (resolvedShellCache.has(cacheKey)) return resolvedShellCache.get(cacheKey);
  const candidates = shellCandidates(sanitizedProfile, sanitizedCustomShell);
  for (const candidate of candidates) {
    if (executableExists(candidate)) {
      resolvedShellCache.set(cacheKey, candidate);
      return candidate;
    }
  }
  const fallback = process.platform === "win32" ? "cmd.exe" : "/bin/sh";
  resolvedShellCache.set(cacheKey, fallback);
  return fallback;
}

function shortPath(rawPath) {
  if (!rawPath) return "";
  const home = os.homedir();
  if (rawPath.toLowerCase().startsWith(home.toLowerCase())) {
    return `~${rawPath.slice(home.length)}`;
  }
  const parts = rawPath.split(/[\\/]+/).filter(Boolean);
  if (parts.length <= 3) return rawPath;
  return `${parts[0]}\\...\\${parts.slice(-2).join("\\")}`;
}

function cleanTerminalTitleSegment(segment) {
  const raw = String(segment || "").trim();
  if (!raw) return "";
  const basename = path.basename(raw).replace(/\.exe$/i, "");
  const lower = raw.toLowerCase();
  if (
    /^pws?h$/i.test(basename) ||
    /^powershell$/i.test(basename) ||
    lower.includes("\\microsoft.powershell_")
  ) {
    return "PowerShell";
  }
  if (/^cmd$/i.test(basename)) return "Command Prompt";
  if (/^[a-z]:[\\/]/i.test(raw) || raw.includes("\\") || raw.includes("/")) {
    return basename || raw;
  }
  return raw;
}

function cleanTerminalTitle(rawTitle) {
  const title = String(rawTitle || "").replace(/\s+/g, " ").trim();
  if (!title) return "";
  const firstSegment = title.split(/\s+·\s+/)[0];
  const cleanedFirstSegment = cleanTerminalTitleSegment(firstSegment);
  if (cleanedFirstSegment && cleanedFirstSegment !== firstSegment) {
    return cleanedFirstSegment.slice(0, 80);
  }
  return title.slice(0, 80);
}

function shellArgs(shellPath) {
  const base = path.basename(shellPath).toLowerCase();
  if (base === "pwsh.exe" || base === "powershell.exe") return ["-NoLogo"];
  return [];
}

class TerminalProcess {
  constructor(panel, options = {}) {
    this.panel = panel;
    this.cols = options.cols || 100;
    this.rows = options.rows || 30;
    this.clients = new Set();
    this.backlog = "";
    this.closed = false;
    this.ptyProcess = null;
    this.child = null;
    this.start();
  }

  start() {
    const shellPath = resolveShell(this.panel.shellProfile, this.panel.shellPath);
    const cwd = this.panel.cwd && fs.existsSync(this.panel.cwd)
      ? this.panel.cwd
      : os.homedir();
    if (pty) {
      this.ptyProcess = pty.spawn(shellPath, shellArgs(shellPath), {
        name: "xterm-256color",
        cols: this.cols,
        rows: this.rows,
        cwd,
        env: {
          ...process.env,
          TERM: "xterm-256color",
          COLORTERM: "truecolor",
          CMUX_WINDOWS: "1",
          CMUX_WORKSPACE_ID: this.panel.workspaceId,
          CMUX_PANEL_ID: this.panel.id
        }
      });
      this.ptyProcess.onData((data) => this.emitOutput(data));
      this.ptyProcess.onExit(({ exitCode }) => {
        this.emitOutput(`\r\n[process exited: ${exitCode}]\r\n`);
        this.closed = true;
      });
      return;
    }

    this.child = spawn(shellPath, shellArgs(shellPath), {
      cwd,
      env: {
        ...process.env,
        CMUX_WINDOWS: "1",
        CMUX_WORKSPACE_ID: this.panel.workspaceId,
        CMUX_PANEL_ID: this.panel.id
      },
      stdio: "pipe",
      windowsHide: true
    });
    this.child.stdout.on("data", (chunk) => this.emitOutput(chunk.toString("utf8")));
    this.child.stderr.on("data", (chunk) => this.emitOutput(chunk.toString("utf8")));
    this.child.on("exit", (code) => {
      this.emitOutput(`\r\n[process exited: ${code ?? "unknown"}]\r\n`);
      this.closed = true;
    });
    this.emitOutput("cmux Windows process bridge fallback is active. Install node-pty for full ConPTY behavior.\r\n");
  }

  attach(socket) {
    this.clients.add(socket);
    if (this.backlog) {
      socket.send(JSON.stringify({ type: "output", data: this.backlog }));
    }
    socket.on("message", (raw) => {
      let message = null;
      try {
        message = JSON.parse(raw.toString("utf8"));
      } catch {
        return;
      }
      if (message.type === "input" && typeof message.data === "string") {
        this.write(message.data);
      }
      if (message.type === "resize") {
        this.resize(message.cols, message.rows);
      }
    });
    socket.on("close", () => this.clients.delete(socket));
  }

  emitOutput(data) {
    this.backlog = (this.backlog + data).slice(-200000);
    const titleMatch = data.match(/\x1b\]0;([^\x07\x1b]+)\x07/);
    if (titleMatch?.[1]) {
      const nextTitle = cleanTerminalTitle(titleMatch[1]);
      if (nextTitle && this.panel.title !== nextTitle) {
        this.panel.title = nextTitle;
        this.panel.runtime.persistAndBroadcast();
      }
    }
    const lower = data.toLowerCase();
    if (
      lower.includes("waiting for input") ||
      lower.includes("needs your input") ||
      lower.includes("permission") ||
      lower.includes("approve")
    ) {
      this.panel.needsAttention = true;
      this.panel.notificationText = data.replace(/\s+/g, " ").trim().slice(0, 160);
      this.panel.runtime.broadcastState();
    }
    const payload = JSON.stringify({ type: "output", data });
    for (const client of this.clients) {
      if (client.readyState === client.OPEN) client.send(payload);
    }
  }

  write(data) {
    if (this.ptyProcess) {
      this.ptyProcess.write(data);
      return;
    }
    if (this.child?.stdin.writable) this.child.stdin.write(data);
  }

  resize(cols, rows) {
    const nextCols = Math.max(2, Math.floor(Number(cols) || this.cols));
    const nextRows = Math.max(2, Math.floor(Number(rows) || this.rows));
    this.cols = nextCols;
    this.rows = nextRows;
    if (this.ptyProcess) this.ptyProcess.resize(nextCols, nextRows);
  }

  close() {
    this.closed = true;
    if (this.ptyProcess) {
      this.ptyProcess.kill();
      this.ptyProcess = null;
    }
    if (this.child && !this.child.killed) {
      this.child.kill();
      this.child = null;
    }
    for (const client of this.clients) client.close();
    this.clients.clear();
  }
}

class CmuxWindowsRuntime {
  constructor(options = {}) {
    this.staticDir = options.staticDir || path.join(__dirname, "..", "renderer");
    this.dataDir = options.dataDir || appDataRoot();
    this.sessionFile = path.join(this.dataDir, "session.json");
    this.pipeName = options.pipeName || defaultPipeName;
    this.server = null;
    this.pipeServer = null;
    this.wss = new WebSocketServer({ noServer: true });
    this.eventSockets = new Set();
    this.terminals = new Map();
    this.state = this.loadSession();
  }

  get ptyAvailable() {
    return Boolean(pty);
  }

  loadSession() {
    try {
      const parsed = JSON.parse(fs.readFileSync(this.sessionFile, "utf8"));
      if (Array.isArray(parsed.workspaces) && parsed.workspaces.length > 0) {
        return {
          activeWorkspaceId: parsed.activeWorkspaceId || parsed.workspaces[0].id,
          workspaces: parsed.workspaces.map((workspace) => ({
            ...workspace,
            color: workspace.color || workspaceColors[0],
            cwd: sanitizeDirectoryPath(workspace.cwd),
            panels: Array.isArray(workspace.panels) && workspace.panels.length > 0
              ? workspace.panels.map((panel) => ({
                ...panel,
                color: panel.color || "",
                cwd: sanitizeDirectoryPath(panel.cwd || workspace.cwd),
                shellProfile: panel.type === "terminal" ? sanitizeShellProfile(panel.shellProfile) : "",
                shellPath: panel.type === "terminal" ? sanitizeShellPath(panel.shellPath) : "",
                terminalFontSize: panel.type === "terminal" ? sanitizeTerminalFontSize(panel.terminalFontSize, 0) : 0,
                runtime: this,
                needsAttention: false,
                notificationText: ""
              }))
              : []
          }))
        };
      }
    } catch {
      // First run or corrupt state: start clean.
    }
    const workspace = this.newWorkspace("Workspace 1");
    return { activeWorkspaceId: workspace.id, workspaces: [workspace] };
  }

  resetSession() {
    for (const terminal of this.terminals.values()) terminal.close();
    this.terminals.clear();
    const workspace = this.newWorkspace("cmux Windows");
    this.state = { activeWorkspaceId: workspace.id, workspaces: [workspace] };
    this.persistAndBroadcast();
    return this.serializedState();
  }

  persistSession() {
    fs.mkdirSync(this.dataDir, { recursive: true });
    const payload = {
      activeWorkspaceId: this.state.activeWorkspaceId,
      workspaces: this.state.workspaces.map((workspace) => ({
        id: workspace.id,
        title: workspace.title,
        color: workspace.color,
        cwd: workspace.cwd,
        activePanelId: workspace.activePanelId,
        splitDirection: workspace.splitDirection,
        panels: workspace.panels.map((panel) => ({
          id: panel.id,
          workspaceId: panel.workspaceId,
          type: panel.type,
          title: panel.title,
          color: panel.color || "",
          cwd: panel.cwd,
          shellProfile: panel.type === "terminal" ? sanitizeShellProfile(panel.shellProfile) : "",
          shellPath: panel.type === "terminal" ? sanitizeShellPath(panel.shellPath) : "",
          terminalFontSize: panel.type === "terminal" ? sanitizeTerminalFontSize(panel.terminalFontSize, 0) : 0,
          url: panel.url
        }))
      }))
    };
    fs.writeFileSync(this.sessionFile, JSON.stringify(payload, null, 2));
  }

  newWorkspace(title, options = {}) {
    const workspaceId = id("workspace");
    const cwd = sanitizeDirectoryPath(options.cwd);
    const panel = this.newPanel("terminal", workspaceId, { cwd });
    return {
      id: workspaceId,
      title: title || "Workspace",
      color: workspaceColors[this.state?.workspaces?.length % workspaceColors.length || 0],
      cwd,
      activePanelId: panel.id,
      splitDirection: "right",
      panels: [panel]
    };
  }

  newPanel(type, workspaceId, options = {}) {
    const defaultTitle = type === "browser" ? "Browser" : "Terminal";
    const title = String(options.title || defaultTitle).trim().slice(0, 80) || defaultTitle;
    const panel = {
      id: id(type === "browser" ? "browser" : "surface"),
      workspaceId,
      type,
      title,
      color: isSafeColorValue(options.color) ? options.color : "",
      cwd: options.cwd || process.cwd(),
      shellProfile: type === "terminal" ? sanitizeShellProfile(options.shellProfile) : "",
      shellPath: type === "terminal" ? sanitizeShellPath(options.shellPath) : "",
      terminalFontSize: type === "terminal" ? sanitizeTerminalFontSize(options.terminalFontSize, 0) : 0,
      url: options.url || defaultBrowserHomeUrl,
      needsAttention: false,
      notificationText: "",
      runtime: this
    };
    return panel;
  }

  serializedState() {
    return {
      activeWorkspaceId: this.state.activeWorkspaceId,
      ptyAvailable: this.ptyAvailable,
      pipeName: this.pipeName,
      palette: workspaceColors,
      workspaces: this.state.workspaces.map((workspace) => this.serializeWorkspace(workspace))
    };
  }

  serializeWorkspace(workspace) {
    const terminalPanels = workspace.panels.filter((panel) => panel.type === "terminal");
    const browserPanels = workspace.panels.filter((panel) => panel.type === "browser");
    const latestNotification = workspace.panels.find((panel) => panel.needsAttention)?.notificationText || "";
    const cwd = workspace.cwd || terminalPanels[0]?.cwd || process.cwd();
    return {
      id: workspace.id,
      title: workspace.title,
      color: workspace.color || workspaceColors[0],
      activePanelId: workspace.activePanelId,
      splitDirection: workspace.splitDirection,
      terminalCount: terminalPanels.length,
      browserCount: browserPanels.length,
      cwd,
      cwdShort: shortPath(cwd),
      branch: "",
      latestNotification,
      panels: workspace.panels.map((panel) => this.serializePanel(panel))
    };
  }

  serializePanel(panel) {
    return {
      id: panel.id,
      workspaceId: panel.workspaceId,
      type: panel.type,
      title: panel.title,
      color: panel.color || "",
      cwd: panel.cwd,
      cwdShort: shortPath(panel.cwd),
      branch: "",
      shellProfile: panel.shellProfile || "",
      shellPath: panel.shellPath || "",
      terminalFontSize: panel.type === "terminal" ? sanitizeTerminalFontSize(panel.terminalFontSize, 0) : 0,
      url: panel.url,
      needsAttention: panel.needsAttention,
      notificationText: panel.notificationText
    };
  }

  activeWorkspace() {
    return this.state.workspaces.find((workspace) => workspace.id === this.state.activeWorkspaceId)
      || this.state.workspaces[0];
  }

  findPanel(panelId) {
    for (const workspace of this.state.workspaces) {
      const panel = workspace.panels.find((candidate) => candidate.id === panelId);
      if (panel) return { workspace, panel };
    }
    return null;
  }

  createWorkspace(title) {
    const workspace = this.newWorkspace(title || `Workspace ${this.state.workspaces.length + 1}`);
    workspace.activePanelId = workspace.panels[0]?.id || null;
    this.state.workspaces.push(workspace);
    this.state.activeWorkspaceId = workspace.id;
    this.persistAndBroadcast();
    return workspace;
  }

  createWorkspaceFromOptions(options = {}) {
    const cwd = sanitizeDirectoryPath(options.cwd);
    const title = options.title || path.basename(cwd) || `Workspace ${this.state.workspaces.length + 1}`;
    const workspace = this.newWorkspace(title, { cwd });
    workspace.activePanelId = workspace.panels[0]?.id || null;
    this.state.workspaces.push(workspace);
    this.state.activeWorkspaceId = workspace.id;
    this.persistAndBroadcast();
    return workspace;
  }

  createPanel(workspaceId, type, options = {}) {
    const workspace = this.state.workspaces.find((candidate) => candidate.id === workspaceId)
      || this.activeWorkspace();
    const panel = this.newPanel(type || "terminal", workspace.id, {
      ...options,
      cwd: sanitizeDirectoryPath(options.cwd || workspace.cwd)
    });
    workspace.cwd = panel.cwd || workspace.cwd;
    workspace.panels.push(panel);
    workspace.activePanelId = panel.id;
    if (options.direction === "down" || options.direction === "right") {
      workspace.splitDirection = options.direction;
    }
    this.persistAndBroadcast();
    return panel;
  }

  closePanel(panelId) {
    const found = this.findPanel(panelId);
    if (!found) return false;
    const { workspace, panel } = found;
    workspace.panels = workspace.panels.filter((candidate) => candidate.id !== panel.id);
    workspace.activePanelId = workspace.panels[0]?.id || null;
    this.terminals.get(panel.id)?.close();
    this.terminals.delete(panel.id);
    this.persistAndBroadcast();
    return true;
  }

  moveWorkspace(workspaceId, beforeWorkspaceId = null) {
    const currentIndex = this.state.workspaces.findIndex((workspace) => workspace.id === workspaceId);
    if (currentIndex < 0 || beforeWorkspaceId === workspaceId) return false;
    const [workspace] = this.state.workspaces.splice(currentIndex, 1);
    const insertIndex = beforeWorkspaceId
      ? this.state.workspaces.findIndex((candidate) => candidate.id === beforeWorkspaceId)
      : -1;
    this.state.workspaces.splice(insertIndex >= 0 ? insertIndex : this.state.workspaces.length, 0, workspace);
    this.state.activeWorkspaceId = workspace.id;
    this.persistAndBroadcast();
    return true;
  }

  movePanel(panelId, targetWorkspaceId, beforePanelId = null) {
    const found = this.findPanel(panelId);
    if (!found) return false;
    const targetWorkspace = this.state.workspaces.find((workspace) => workspace.id === targetWorkspaceId) || found.workspace;
    if (!targetWorkspace) return false;
    if (beforePanelId === panelId) return true;
    found.workspace.panels = found.workspace.panels.filter((candidate) => candidate.id !== panelId);
    if (found.workspace.activePanelId === panelId) {
      found.workspace.activePanelId = found.workspace.panels[0]?.id || null;
    }
    found.panel.workspaceId = targetWorkspace.id;
    const insertIndex = beforePanelId
      ? targetWorkspace.panels.findIndex((candidate) => candidate.id === beforePanelId)
      : -1;
    targetWorkspace.panels.splice(insertIndex >= 0 ? insertIndex : targetWorkspace.panels.length, 0, found.panel);
    targetWorkspace.activePanelId = panelId;
    this.state.activeWorkspaceId = targetWorkspace.id;
    return true;
  }

  updatePanel(panelId, updates = {}) {
    if (Object.hasOwn(updates, "workspaceId") || Object.hasOwn(updates, "beforePanelId") || Object.hasOwn(updates, "moveToEnd")) {
      const ok = this.movePanel(panelId, updates.workspaceId, updates.moveToEnd ? null : updates.beforePanelId);
      if (!ok) return false;
    }
    const found = this.findPanel(panelId);
    if (!found) return false;
    if (Object.hasOwn(updates, "title")) {
      const title = String(updates.title || "").trim();
      if (title) found.panel.title = title.slice(0, 80);
    }
    if (Object.hasOwn(updates, "color")) {
      const color = String(updates.color || "").trim();
      found.panel.color = isSafeColorValue(color) ? color : "";
    }
    if (updates.direction === "down" || updates.direction === "right") {
      found.workspace.splitDirection = updates.direction;
    }
    if (Object.hasOwn(updates, "url") && found.panel.type === "browser") {
      const url = String(updates.url || "").trim();
      if (/^https?:\/\//i.test(url)) found.panel.url = url.slice(0, 2048);
    }
    if (Object.hasOwn(updates, "terminalFontSize") && found.panel.type === "terminal") {
      found.panel.terminalFontSize = sanitizeTerminalFontSize(updates.terminalFontSize, 0);
    }
    this.persistAndBroadcast();
    return true;
  }

  restartPanel(panelId) {
    const found = this.findPanel(panelId);
    if (!found || found.panel.type !== "terminal") return false;
    this.terminals.get(found.panel.id)?.close();
    this.terminals.delete(found.panel.id);
    found.panel.title = "Terminal";
    found.panel.needsAttention = false;
    found.panel.notificationText = "";
    this.persistAndBroadcast();
    return true;
  }

  closeWorkspace(workspaceId) {
    const workspace = this.state.workspaces.find((candidate) => candidate.id === workspaceId);
    if (!workspace) return false;
    for (const panel of workspace.panels) {
      this.terminals.get(panel.id)?.close();
      this.terminals.delete(panel.id);
    }
    if (this.state.workspaces.length <= 1) {
      workspace.title = "cmux Windows";
      workspace.panels = [];
      workspace.activePanelId = null;
      this.persistAndBroadcast();
      return true;
    }
    this.state.workspaces = this.state.workspaces.filter((candidate) => candidate.id !== workspace.id);
    if (this.state.activeWorkspaceId === workspace.id) {
      this.state.activeWorkspaceId = this.state.workspaces[0].id;
    }
    this.persistAndBroadcast();
    return true;
  }

  updateWorkspace(workspaceId, updates = {}) {
    if (Object.hasOwn(updates, "beforeWorkspaceId") || Object.hasOwn(updates, "moveToEnd")) {
      return this.moveWorkspace(workspaceId, updates.moveToEnd ? null : updates.beforeWorkspaceId);
    }
    const workspace = this.state.workspaces.find((candidate) => candidate.id === workspaceId);
    if (!workspace) return false;
    if (Object.hasOwn(updates, "title")) {
      const trimmed = String(updates.title || "").trim();
      if (!trimmed) return false;
      workspace.title = trimmed.slice(0, 80);
    }
    if (Object.hasOwn(updates, "color")) {
      const color = String(updates.color || "").trim();
      if (isSafeColorValue(color)) workspace.color = color;
    }
    if (Object.hasOwn(updates, "cwd")) {
      const cwd = sanitizeDirectoryPath(updates.cwd, "");
      if (!cwd) return false;
      workspace.cwd = cwd;
    }
    this.persistAndBroadcast();
    return true;
  }

  renameWorkspace(workspaceId, title) {
    return this.updateWorkspace(workspaceId, { title });
  }

  focusWorkspace(workspaceId) {
    if (!this.state.workspaces.some((workspace) => workspace.id === workspaceId)) return false;
    this.state.activeWorkspaceId = workspaceId;
    this.persistAndBroadcast();
    return true;
  }

  focusPanel(panelId) {
    const found = this.findPanel(panelId);
    if (!found) return false;
    this.state.activeWorkspaceId = found.workspace.id;
    found.workspace.activePanelId = panelId;
    found.panel.needsAttention = false;
    found.panel.notificationText = "";
    this.persistAndBroadcast();
    return true;
  }

  notify(message) {
    const workspace = this.activeWorkspace();
    const panel = workspace.panels.find((candidate) => candidate.id === workspace.activePanelId)
      || workspace.panels[0];
    if (!panel) return null;
    panel.needsAttention = true;
    panel.notificationText = String(message || "Notification").slice(0, 160);
    this.broadcastState();
    return panel;
  }

  sendInput(text, panelId) {
    const workspace = this.activeWorkspace();
    const targetPanelId = panelId || workspace?.activePanelId;
    const found = targetPanelId ? this.findPanel(targetPanelId) : null;
    if (!found || found.panel.type !== "terminal") return false;
    let terminal = this.terminals.get(found.panel.id);
    if (!terminal || terminal.closed) {
      terminal = new TerminalProcess(found.panel);
      this.terminals.set(found.panel.id, terminal);
    }
    terminal.write(String(text || ""));
    return true;
  }

  persistAndBroadcast() {
    this.persistSession();
    this.broadcastState();
  }

  broadcastState() {
    const payload = JSON.stringify({ type: "state", state: this.serializedState() });
    for (const socket of this.eventSockets) {
      if (socket.readyState === WebSocket.OPEN) socket.send(payload);
    }
  }

  async handleApi(request, response, url) {
    try {
      if (request.method === "GET" && url.pathname === "/api/state") {
        writeJSON(response, 200, this.serializedState());
        return;
      }
      if (request.method === "POST" && url.pathname === "/api/workspaces") {
        const body = await readBody(request);
        writeJSON(response, 200, this.serializeWorkspace(this.createWorkspaceFromOptions(body)));
        return;
      }
      if (request.method === "POST" && url.pathname === "/api/session/reset") {
        writeJSON(response, 200, this.resetSession());
        return;
      }
      if (request.method === "POST" && url.pathname === "/api/panels") {
        const body = await readBody(request);
        writeJSON(response, 200, this.serializePanel(this.createPanel(body.workspaceId, body.type, body)));
        return;
      }
      const focusWorkspaceMatch = url.pathname.match(/^\/api\/workspaces\/([^/]+)\/focus$/);
      if (request.method === "POST" && focusWorkspaceMatch) {
        const ok = this.focusWorkspace(focusWorkspaceMatch[1]);
        writeJSON(response, ok ? 200 : 404, { ok });
        return;
      }
      const workspaceDeleteMatch = url.pathname.match(/^\/api\/workspaces\/([^/]+)$/);
      if (request.method === "DELETE" && workspaceDeleteMatch) {
        const ok = this.closeWorkspace(workspaceDeleteMatch[1]);
        writeJSON(response, ok ? 200 : 409, { ok });
        return;
      }
      const workspaceRenameMatch = url.pathname.match(/^\/api\/workspaces\/([^/]+)$/);
      if (request.method === "PATCH" && workspaceRenameMatch) {
        const body = await readBody(request);
        const ok = this.updateWorkspace(workspaceRenameMatch[1], body);
        writeJSON(response, ok ? 200 : 404, { ok });
        return;
      }
      const panelFocusMatch = url.pathname.match(/^\/api\/panels\/([^/]+)\/focus$/);
      if (request.method === "POST" && panelFocusMatch) {
        const ok = this.focusPanel(panelFocusMatch[1]);
        writeJSON(response, ok ? 200 : 404, { ok });
        return;
      }
      const panelRestartMatch = url.pathname.match(/^\/api\/panels\/([^/]+)\/restart$/);
      if (request.method === "POST" && panelRestartMatch) {
        const ok = this.restartPanel(panelRestartMatch[1]);
        writeJSON(response, ok ? 200 : 404, { ok });
        return;
      }
      const panelDeleteMatch = url.pathname.match(/^\/api\/panels\/([^/]+)$/);
      if (request.method === "DELETE" && panelDeleteMatch) {
        const ok = this.closePanel(panelDeleteMatch[1]);
        writeJSON(response, ok ? 200 : 409, { ok });
        return;
      }
      const panelUpdateMatch = url.pathname.match(/^\/api\/panels\/([^/]+)$/);
      if (request.method === "PATCH" && panelUpdateMatch) {
        const body = await readBody(request);
        const ok = this.updatePanel(panelUpdateMatch[1], body);
        writeJSON(response, 200, { ok });
        return;
      }
      if (request.method === "POST" && url.pathname === "/api/notify") {
        const body = await readBody(request);
        const panel = this.notify(body.message);
        writeJSON(response, 200, { panel: panel ? this.serializePanel(panel) : null });
        return;
      }
      if (request.method === "POST" && url.pathname === "/api/input") {
        const body = await readBody(request);
        const ok = this.sendInput(body.text, body.panelId);
        writeJSON(response, ok ? 200 : 404, { ok });
        return;
      }
      writeJSON(response, 404, { error: "not_found" });
    } catch (error) {
      writeJSON(response, 500, { error: error.message });
    }
  }

  serveStatic(request, response, url) {
    const vendor = this.vendorFile(url.pathname);
    const filePath = vendor || path.join(this.staticDir, url.pathname === "/" ? "index.html" : url.pathname);
    const resolved = path.resolve(filePath);
    const allowedRoots = [path.resolve(this.staticDir), path.resolve(path.join(__dirname, "..", "node_modules"))];
    if (!allowedRoots.some((root) => resolved === root || resolved.startsWith(root + path.sep))) {
      response.writeHead(403);
      response.end("Forbidden");
      return;
    }
    fs.readFile(resolved, (error, data) => {
      if (error) {
        response.writeHead(404);
        response.end("Not found");
        return;
      }
      response.writeHead(200, { "content-type": this.contentType(resolved) });
      response.end(data);
    });
  }

  serveLocalImage(request, response, url) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      response.writeHead(405);
      response.end("Method not allowed");
      return;
    }
    const filePath = localImagePathFromUrl(url.searchParams.get("url"));
    if (!filePath) {
      response.writeHead(404);
      response.end("Not found");
      return;
    }
    const contentType = localImageContentTypes.get(path.extname(filePath).toLowerCase()) || "application/octet-stream";
    fs.stat(filePath, (statError, stat) => {
      if (statError || !stat.isFile()) {
        response.writeHead(404);
        response.end("Not found");
        return;
      }
      response.writeHead(200, {
        "content-type": contentType,
        "content-length": stat.size,
        "cache-control": "private, max-age=60"
      });
      if (request.method === "HEAD") {
        response.end();
        return;
      }
      fs.createReadStream(filePath).on("error", () => {
        if (!response.headersSent) response.writeHead(500);
        response.end();
      }).pipe(response);
    });
  }

  vendorFile(pathname) {
    const root = path.join(__dirname, "..", "node_modules");
    const files = {
      "/vendor/xterm.css": path.join(root, "@xterm", "xterm", "css", "xterm.css"),
      "/vendor/xterm.js": path.join(root, "@xterm", "xterm", "lib", "xterm.js"),
      "/vendor/addon-fit.js": path.join(root, "@xterm", "addon-fit", "lib", "addon-fit.js"),
      "/vendor/addon-web-links.js": path.join(root, "@xterm", "addon-web-links", "lib", "addon-web-links.js"),
      "/vendor/addon-search.js": path.join(root, "@xterm", "addon-search", "lib", "addon-search.js")
    };
    return files[pathname];
  }

  contentType(filePath) {
    const ext = path.extname(filePath).toLowerCase();
    if (ext === ".html") return "text/html; charset=utf-8";
    if (ext === ".css") return "text/css; charset=utf-8";
    if (ext === ".js") return "text/javascript; charset=utf-8";
    if (ext === ".json") return "application/json; charset=utf-8";
    if (ext === ".svg") return "image/svg+xml; charset=utf-8";
    return "application/octet-stream";
  }

  handleUpgrade(request, socket, head) {
    const url = new URL(request.url, "http://127.0.0.1");
    this.wss.handleUpgrade(request, socket, head, (ws) => {
      if (url.pathname === "/events") {
        this.eventSockets.add(ws);
        ws.send(JSON.stringify({ type: "state", state: this.serializedState() }));
        ws.on("close", () => this.eventSockets.delete(ws));
        return;
      }
      const match = url.pathname.match(/^\/terminal\/([^/]+)$/);
      if (match) {
        const found = this.findPanel(match[1]);
        if (!found || found.panel.type !== "terminal") {
          ws.close();
          return;
        }
        let terminal = this.terminals.get(found.panel.id);
        if (!terminal || terminal.closed) {
          terminal = new TerminalProcess(found.panel);
          this.terminals.set(found.panel.id, terminal);
        }
        terminal.attach(ws);
        return;
      }
      ws.close();
    });
  }

  listen(port = 0) {
    return new Promise((resolve, reject) => {
      this.server = http.createServer((request, response) => {
        const url = new URL(request.url, "http://127.0.0.1");
        if (url.pathname.startsWith("/api/")) {
          this.handleApi(request, response, url);
        } else if (url.pathname === "/_cmux/local-image") {
          this.serveLocalImage(request, response, url);
        } else {
          this.serveStatic(request, response, url);
        }
      });
      this.server.on("upgrade", (request, socket, head) => this.handleUpgrade(request, socket, head));
      this.server.on("error", reject);
      this.server.listen(port, "127.0.0.1", () => {
        this.startPipeServer();
        const address = this.server.address();
        resolve({
          port: address.port,
          url: `http://127.0.0.1:${address.port}/`,
          pipeName: this.pipeName,
          ptyAvailable: this.ptyAvailable
        });
      });
    });
  }

  startPipeServer() {
    if (process.platform !== "win32" && fs.existsSync(this.pipeName)) {
      fs.unlinkSync(this.pipeName);
    }
    this.pipeServer = net.createServer((socket) => {
      let buffer = "";
      socket.on("data", (chunk) => {
        buffer += chunk.toString("utf8");
        let index = buffer.indexOf("\n");
        while (index >= 0) {
          const line = buffer.slice(0, index).trim();
          buffer = buffer.slice(index + 1);
          this.handlePipeLine(line).then((reply) => {
            socket.write(reply + "\n");
          }).catch((error) => {
            socket.write(JSON.stringify({ ok: false, error: error.message }) + "\n");
          });
          index = buffer.indexOf("\n");
        }
      });
    });
    this.pipeServer.on("error", () => {});
    this.pipeServer.listen(this.pipeName);
  }

  async handlePipeLine(line) {
    if (!line) return "ERROR empty command";
    if (line.startsWith("{")) {
      const request = JSON.parse(line);
      const result = this.handleRpc(request.method, request.params || {});
      return JSON.stringify({ jsonrpc: "2.0", id: request.id ?? null, result });
    }
    const [command, ...args] = line.split(/\s+/);
    switch (command) {
      case "ping":
        return "OK";
      case "list-workspaces":
        return JSON.stringify(this.serializedState().workspaces);
      case "new-workspace":
        return JSON.stringify(this.serializeWorkspace(this.createWorkspace(args.join(" ") || undefined)));
      case "reset-session":
        return JSON.stringify(this.resetSession());
      case "new-terminal":
        return JSON.stringify(this.serializePanel(this.createPanel(this.state.activeWorkspaceId, "terminal")));
      case "browser-open":
        return JSON.stringify(this.serializePanel(this.createPanel(this.state.activeWorkspaceId, "browser", { url: args.join(" ") || defaultBrowserHomeUrl })));
      case "restart-terminal":
        return this.restartPanel(this.activeWorkspace()?.activePanelId) ? "OK" : "ERROR no active terminal";
      case "notify":
        return JSON.stringify(this.serializePanel(this.notify(args.join(" ") || "Notification")));
      case "send":
        return this.sendInput(`${args.join(" ")}\r`) ? "OK" : "ERROR no active terminal";
      default:
        return `ERROR unknown command: ${command}`;
    }
  }

  handleRpc(method, params) {
    switch (method) {
      case "system.ping":
        return { ok: true };
      case "workspace.list":
        return this.serializedState().workspaces;
      case "workspace.create":
        return this.serializeWorkspace(this.createWorkspaceFromOptions(params));
      case "workspace.update":
        return { ok: this.updateWorkspace(params.workspaceId || this.state.activeWorkspaceId, params) };
      case "workspace.rename":
        return { ok: this.renameWorkspace(params.workspaceId || this.state.activeWorkspaceId, params.title) };
      case "workspace.close":
        return { ok: this.closeWorkspace(params.workspaceId || this.state.activeWorkspaceId) };
      case "session.reset":
        return this.resetSession();
      case "panel.create":
        return this.serializePanel(this.createPanel(params.workspaceId || this.state.activeWorkspaceId, params.type || "terminal", params));
      case "browser.open":
        return this.serializePanel(this.createPanel(params.workspaceId || this.state.activeWorkspaceId, "browser", { url: params.url || defaultBrowserHomeUrl }));
      case "panel.update":
        return { ok: this.updatePanel(params.panelId, params) };
      case "terminal.restart":
        return { ok: this.restartPanel(params.panelId || this.activeWorkspace()?.activePanelId) };
      case "notification.create":
        return this.serializePanel(this.notify(params.message || params.body || "Notification"));
      case "terminal.send":
        return { ok: this.sendInput(params.text || "", params.panelId) };
      default:
        throw new Error(`unknown method: ${method}`);
    }
  }

  close() {
    for (const terminal of this.terminals.values()) terminal.close();
    this.terminals.clear();
    for (const socket of this.eventSockets) socket.close();
    this.eventSockets.clear();
    this.wss.close();
    this.pipeServer?.close();
    this.server?.close();
    if (process.platform !== "win32" && fs.existsSync(this.pipeName)) {
      try { fs.unlinkSync(this.pipeName); } catch {}
    }
  }
}

function createCmuxWindowsRuntime(options) {
  return new CmuxWindowsRuntime(options);
}

module.exports = { createCmuxWindowsRuntime, defaultPipeName };
