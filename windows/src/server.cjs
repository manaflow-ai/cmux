const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { fileURLToPath } = require("node:url");
const { spawn, spawnSync } = require("node:child_process");
const { WebSocket, WebSocketServer } = require("ws");
const { t } = require("./i18n.cjs");

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
const terminalMetadataBroadcastDelayMs = 160;
const gitBranchCacheTtlMs = 5000;
const apiRequestBodyLimitBytes = 1024 * 1024;
const pipeReadBufferLimitBytes = 1024 * 1024;

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

class RequestBodyTooLargeError extends Error {
  constructor() {
    super("request_body_too_large");
    this.name = "RequestBodyTooLargeError";
  }
}

function readBody(request, limitBytes = apiRequestBodyLimitBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalBytes = 0;
    let settled = false;
    const cleanup = () => {
      request.removeListener("data", onData);
      request.removeListener("end", onEnd);
      request.removeListener("error", onError);
    };
    const fail = (error) => {
      if (settled) return;
      settled = true;
      cleanup();
      request.resume();
      reject(error);
    };
    const onData = (chunk) => {
      totalBytes += chunk.length;
      if (totalBytes > limitBytes) {
        fail(new RequestBodyTooLargeError());
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = () => {
      if (settled) return;
      settled = true;
      cleanup();
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
    };
    const onError = (error) => fail(error);
    request.on("data", onData);
    request.on("end", onEnd);
    request.on("error", onError);
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

function validBrowserUrl(value) {
  try {
    const parsed = new URL(String(value || "").trim());
    if (!["http:", "https:"].includes(parsed.protocol)) return "";
    return parsed.href.length <= 2048 ? parsed.href : "";
  } catch {
    return "";
  }
}

function sanitizeBrowserUrl(value, fallback = defaultBrowserHomeUrl) {
  return validBrowserUrl(value) || validBrowserUrl(fallback) || defaultBrowserHomeUrl;
}

const shellProfileIds = new Set(["auto", "pwsh", "powershell", "cmd", "wsl", "git-bash", "custom"]);
const executableExistsCache = new Map();
const resolvedShellCache = new Map();
const gitBranchCache = new Map();

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

function sanitizeRendererPort(value) {
  const port = Number(value);
  return Number.isInteger(port) && port > 0 && port < 65536 ? port : 0;
}

function defaultWorkspaceDirectory() {
  const home = os.homedir();
  return home && fs.existsSync(home) ? home : process.cwd();
}

function sanitizeDirectoryPath(value, fallback = defaultWorkspaceDirectory()) {
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
  } else if (process.platform === "win32") {
    exists = windowsExecutableOnPath(candidate);
  } else {
    const probe = spawnSync("command", ["-v", candidate], { shell: true, stdio: "ignore" });
    exists = probe.status === 0;
  }
  executableExistsCache.set(cacheKey, exists);
  return exists;
}

function windowsExecutableOnPath(candidate) {
  const pathext = (process.env.PATHEXT || process.env.Pathext || ".COM;.EXE;.BAT;.CMD")
    .split(";")
    .map((ext) => ext.trim().toLowerCase())
    .filter(Boolean);
  const names = path.extname(candidate)
    ? [candidate]
    : pathext.map((ext) => `${candidate}${ext}`);
  const pathEntries = (process.env.PATH || process.env.Path || "")
    .split(path.delimiter)
    .map((entry) => entry.trim().replace(/^"|"$/g, ""))
    .filter(Boolean);
  for (const entry of pathEntries) {
    for (const name of names) {
      try {
        if (fs.existsSync(path.join(entry, name))) return true;
      } catch {
        // Ignore malformed PATH entries.
      }
    }
  }
  return false;
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

function gitCommonDir(gitDir) {
  try {
    const value = fs
      .readFileSync(path.join(gitDir, "commondir"), "utf8")
      .trim();
    return value ? path.resolve(gitDir, value) : gitDir;
  } catch {
    return gitDir;
  }
}

function packedRefExists(gitDir, refName) {
  try {
    const content = fs.readFileSync(path.join(gitDir, "packed-refs"), "utf8");
    return content.split(/\r?\n/).some((line) => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#") || trimmed.startsWith("^")) {
        return false;
      }
      const [, ref] = trimmed.split(/\s+/);
      return ref === refName;
    });
  } catch {
    return false;
  }
}

function gitRefExists(gitDir, refName) {
  const roots = Array.from(new Set([gitDir, gitCommonDir(gitDir)]));
  return roots.some((root) => {
    const refPath = path.join(root, ...refName.split("/"));
    return fs.existsSync(refPath) || packedRefExists(root, refName);
  });
}

function branchFromGitDir(gitDir) {
  try {
    const head = fs.readFileSync(path.join(gitDir, "HEAD"), "utf8").trim();
    const refPrefix = "ref: ";
    const branchPrefix = "refs/heads/";
    if (!head.startsWith(refPrefix)) return "";
    const refName = head.slice(refPrefix.length).trim();
    if (!refName.startsWith(branchPrefix) || !gitRefExists(gitDir, refName)) {
      return "";
    }
    return refName.slice(branchPrefix.length).slice(0, 80);
  } catch {
    return "";
  }
}

function gitBranch(rawPath) {
  const cwd = String(rawPath || "").trim();
  if (!cwd) return "";
  const resolved = path.resolve(cwd);
  const now = Date.now();
  const cached = gitBranchCache.get(resolved);
  if (cached && now - cached.at < gitBranchCacheTtlMs) return cached.branch;
  let branch = "";
  try {
    const current = fs.existsSync(resolved) && fs.statSync(resolved).isDirectory()
      ? resolved
      : path.dirname(resolved);
    const dotGit = path.join(current, ".git");
    if (fs.existsSync(dotGit)) {
      const stat = fs.statSync(dotGit);
      if (stat.isDirectory()) {
        branch = branchFromGitDir(dotGit);
      } else if (stat.isFile()) {
        const match = fs.readFileSync(dotGit, "utf8").match(/^gitdir:\s*(.+)\s*$/im);
        if (match) {
          const gitDir = path.isAbsolute(match[1]) ? match[1] : path.resolve(current, match[1]);
          branch = branchFromGitDir(gitDir);
        }
      }
    }
  } catch {
    branch = "";
  }
  gitBranchCache.set(resolved, { at: now, branch });
  return branch;
}

function normalizedTitleKey(value) {
  return String(value || "").trim().replace(/\s+/g, " ").toLowerCase();
}

function workspaceTitle(value, fallback = "Workspace") {
  const title = String(value || "").trim().replace(/\s+/g, " ");
  return (title || fallback).slice(0, 80);
}

function generatedWorkspaceTitleFromUsed(baseTitle = "Workspace", usedTitles = new Set()) {
  const base = workspaceTitle(baseTitle);
  const generatedMatch = base.match(/^Workspace(?:\s+(\d+))?$/i);
  if (generatedMatch) {
    const startIndex = Math.max(1, Number(generatedMatch[1] || 1) || 1);
    for (let index = startIndex; index < 10000; index += 1) {
      const candidate = `Workspace ${index}`;
      if (!usedTitles.has(normalizedTitleKey(candidate))) return candidate;
    }
  }
  if (!usedTitles.has(normalizedTitleKey(base))) return base;
  const truncatedBase = base.slice(0, 74).trim() || "Workspace";
  for (let index = 2; index < 10000; index += 1) {
    const candidate = `${truncatedBase} ${index}`.slice(0, 80);
    if (!usedTitles.has(normalizedTitleKey(candidate))) return candidate;
  }
  return `${truncatedBase} ${Date.now().toString(36)}`.slice(0, 80);
}

function repairWorkspaceTitles(workspaces) {
  const usedTitles = new Set();
  for (const workspace of workspaces) {
    const title = workspaceTitle(workspace.title);
    const key = normalizedTitleKey(title);
    const generatedTitle = /^workspace(?:\s+\d+)?$/i.test(title);
    if (!usedTitles.has(key)) {
      workspace.title = title;
      usedTitles.add(key);
      continue;
    }
    if (!generatedTitle) continue;
    const repairedTitle = generatedWorkspaceTitleFromUsed(title, usedTitles);
    workspace.title = repairedTitle;
    usedTitles.add(normalizedTitleKey(repairedTitle));
  }
  return workspaces;
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

function tokensMatch(expected, actual) {
  const left = Buffer.from(String(expected || ""));
  const right = Buffer.from(String(actual || ""));
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function terminalProcessEnv(panel, panelToken, extra = {}) {
  const env = { ...process.env };
  delete env.CMUX_WINDOWS_TOKEN;
  delete env.CMUX_WINDOWS_PANEL_TOKEN;
  return {
    ...env,
    ...extra,
    CMUX_WINDOWS: "1",
    CMUX_WINDOWS_PIPE: panel.runtime?.pipeName || defaultPipeName,
    CMUX_WINDOWS_PANEL_TOKEN: panelToken,
    CMUX_WORKSPACE_ID: panel.workspaceId,
    CMUX_PANEL_ID: panel.id
  };
}

const terminalAttentionPatterns = [
  /\bwaiting for (?:your )?input\b/i,
  /\bneeds (?:your )?input\b/i,
  /\brequires? (?:your )?input\b/i,
  /\b(?:press|hit) (?:enter|return|y|n|a key) (?:to|for)\b/i,
  /\bpermission (?:requested|required|needed|prompt|approval)\b/i,
  /\b(?:approve|approval|confirm|authorize|allow|grant permission)\b.{0,120}\?/i,
  /\b(?:continue|proceed)\?\s*$/i
];

function terminalAttentionText(data) {
  return String(data || "")
    .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function terminalOutputNeedsAttention(data) {
  const text = terminalAttentionText(data);
  return Boolean(text && terminalAttentionPatterns.some((pattern) => pattern.test(text)));
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
    this.panelToken = crypto.randomBytes(32).toString("hex");
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
        env: terminalProcessEnv(this.panel, this.panelToken, {
          TERM: "xterm-256color",
          COLORTERM: "truecolor"
        })
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
      env: terminalProcessEnv(this.panel, this.panelToken),
      stdio: "pipe",
      windowsHide: true
    });
    this.child.stdout.on("data", (chunk) => this.emitOutput(chunk.toString("utf8")));
    this.child.stderr.on("data", (chunk) => this.emitOutput(chunk.toString("utf8")));
    this.child.on("exit", (code) => {
      this.emitOutput(`\r\n[process exited: ${code ?? "unknown"}]\r\n`);
      this.closed = true;
    });
    this.emitOutput("cmux is using compatibility shell mode. Some interactive shell features may be limited.\r\n");
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
    if (titleMatch?.[1] && !this.panel.titleLocked) {
      const nextTitle = cleanTerminalTitle(titleMatch[1]);
      if (nextTitle && this.panel.title !== nextTitle) {
        this.panel.title = nextTitle;
        this.panel.runtime.scheduleTerminalMetadataBroadcast();
      }
    }
    if (terminalOutputNeedsAttention(data)) {
      const notificationText = data.replace(/\s+/g, " ").trim().slice(0, 160);
      if (!this.panel.needsAttention || this.panel.notificationText !== notificationText) {
        this.panel.needsAttention = true;
        this.panel.notificationText = notificationText;
        this.panel.runtime.scheduleTerminalMetadataBroadcast();
      }
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
    if (this.child?.stdin.writable) {
      this.child.stdin.write(data);
    }
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
    this.pendingTerminalPrewarms = new Map();
    this.terminalMetadataTimer = null;
    this.launchToken = String(options.launchToken || crypto.randomBytes(32).toString("base64url"));
    this.closed = false;
    this.sessionRepaired = false;
    this.state = this.loadSession();
    if (this.sessionRepaired) this.persistSession();
  }

  get ptyAvailable() {
    return Boolean(pty);
  }

  loadSession() {
    try {
      const parsed = JSON.parse(fs.readFileSync(this.sessionFile, "utf8"));
      if (Array.isArray(parsed.workspaces) && parsed.workspaces.length > 0) {
        const titleSignatureBefore = parsed.workspaces.map((workspace) => workspaceTitle(workspace.title)).join("\0");
        const workspaces = repairWorkspaceTitles(parsed.workspaces.map((workspace) => ({
          ...workspace,
          color: workspace.color || workspaceColors[0],
          cwd: sanitizeDirectoryPath(workspace.cwd),
          panels: Array.isArray(workspace.panels) && workspace.panels.length > 0
            ? workspace.panels.map((panel) => ({
              ...panel,
              titleLocked: Boolean(panel.titleLocked),
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
        })));
        const titleSignatureAfter = workspaces.map((workspace) => workspace.title).join("\0");
        this.sessionRepaired = titleSignatureBefore !== titleSignatureAfter;
        return {
          activeWorkspaceId: parsed.activeWorkspaceId || parsed.workspaces[0].id,
          rendererPort: sanitizeRendererPort(parsed.rendererPort),
          workspaces
        };
      }
    } catch {
      // First run or corrupt state: start clean.
    }
    const workspace = this.newWorkspace("Workspace 1");
    return { activeWorkspaceId: workspace.id, rendererPort: 0, workspaces: [workspace] };
  }

  resetSession() {
    for (const terminal of this.terminals.values()) terminal.close();
    this.terminals.clear();
    const rendererPort = sanitizeRendererPort(this.state.rendererPort);
    const workspace = this.newWorkspace("cmux Windows");
    this.state = { activeWorkspaceId: workspace.id, rendererPort, workspaces: [workspace] };
    this.persistAndBroadcast();
    return this.serializedState();
  }

  persistSession() {
    fs.mkdirSync(this.dataDir, { recursive: true });
    const payload = {
      activeWorkspaceId: this.state.activeWorkspaceId,
      rendererPort: sanitizeRendererPort(this.state.rendererPort),
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
          titleLocked: Boolean(panel.titleLocked),
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
      title: workspaceTitle(title),
      color: workspaceColors[this.state?.workspaces?.length % workspaceColors.length || 0],
      cwd,
      activePanelId: panel.id,
      splitDirection: "right",
      panels: [panel]
    };
  }

  generatedWorkspaceTitle(baseTitle = "Workspace") {
    const existing = new Set(this.state.workspaces.map((workspace) => normalizedTitleKey(workspace.title)));
    return generatedWorkspaceTitleFromUsed(baseTitle, existing);
  }

  newPanel(type, workspaceId, options = {}) {
    const defaultTitle = type === "browser" ? t("panel.browser") : t("panel.terminal");
    const explicitTitle = String(options.title || "").trim();
    const title = String(explicitTitle || defaultTitle).trim().slice(0, 80) || defaultTitle;
    const panel = {
      id: id(type === "browser" ? "browser" : "surface"),
      workspaceId,
      type,
      title,
      titleLocked: Boolean(explicitTitle || options.titleLocked),
      color: isSafeColorValue(options.color) ? options.color : "",
      cwd: sanitizeDirectoryPath(options.cwd),
      shellProfile: type === "terminal" ? sanitizeShellProfile(options.shellProfile) : "",
      shellPath: type === "terminal" ? sanitizeShellPath(options.shellPath) : "",
      terminalFontSize: type === "terminal" ? sanitizeTerminalFontSize(options.terminalFontSize, 0) : 0,
      url: type === "browser" ? sanitizeBrowserUrl(options.url) : defaultBrowserHomeUrl,
      needsAttention: false,
      notificationText: "",
      runtime: this
    };
    return panel;
  }

  serializedState() {
    return {
      activeWorkspaceId: this.state.activeWorkspaceId,
      rendererPort: sanitizeRendererPort(this.state.rendererPort),
      ptyAvailable: this.ptyAvailable,
      pipeName: this.pipeName,
      palette: workspaceColors,
      workspaces: this.state.workspaces.map((workspace) => this.serializeWorkspace(workspace))
    };
  }

  serializeWorkspace(workspace) {
    const panels = Array.isArray(workspace.panels) ? workspace.panels : [];
    let terminalCount = 0;
    let browserCount = 0;
    let firstTerminalCwd = "";
    let latestNotification = "";
    for (const panel of panels) {
      if (panel.type === "terminal") {
        terminalCount += 1;
        if (!firstTerminalCwd) firstTerminalCwd = panel.cwd || "";
      } else if (panel.type === "browser") {
        browserCount += 1;
      }
      if (!latestNotification && panel.needsAttention) {
        latestNotification = panel.notificationText || "";
      }
    }
    const cwd = workspace.cwd || firstTerminalCwd || defaultWorkspaceDirectory();
    const branch = gitBranch(cwd);
    return {
      id: workspace.id,
      title: workspace.title,
      color: workspace.color || workspaceColors[0],
      activePanelId: workspace.activePanelId,
      splitDirection: workspace.splitDirection,
      terminalCount,
      browserCount,
      cwd,
      cwdShort: shortPath(cwd),
      branch,
      latestNotification,
      panels: panels.map((panel) => this.serializePanel(panel))
    };
  }

  serializePanel(panel) {
    return {
      id: panel.id,
      workspaceId: panel.workspaceId,
      type: panel.type,
      title: panel.title,
      titleLocked: Boolean(panel.titleLocked),
      color: panel.color || "",
      cwd: panel.cwd,
      cwdShort: shortPath(panel.cwd),
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

  ensureTerminalProcess(panel) {
    if (!panel || panel.type !== "terminal") return null;
    let terminal = this.terminals.get(panel.id);
    if (!terminal || terminal.closed) {
      terminal = new TerminalProcess(panel);
      this.terminals.set(panel.id, terminal);
    }
    return terminal;
  }

  hasRendererEventSocket() {
    for (const socket of this.eventSockets) {
      if (socket.readyState === WebSocket.OPEN) return true;
    }
    return false;
  }

  scheduleTerminalPrewarm(panel) {
    if (this.closed || !panel || panel.type !== "terminal" || !this.hasRendererEventSocket()) return;
    if (this.terminals.has(panel.id) || this.pendingTerminalPrewarms.has(panel.id)) return;
    const panelId = panel.id;
    const pending = { canceled: false, handle: null, handleType: "" };
    const run = () => {
      if (pending.canceled) return;
      this.pendingTerminalPrewarms.delete(panelId);
      if (this.closed) return;
      try {
        const found = this.findPanel(panelId);
        if (!found || found.panel.type !== "terminal" || this.terminals.has(panelId)) return;
        this.ensureTerminalProcess(found.panel);
      } catch (error) {
        console.error("terminal prewarm failed");
        console.error(error);
      }
    };
    this.pendingTerminalPrewarms.set(panelId, pending);
    // Let the panel-create response reach the renderer before terminal spawn can
    // spend time in native process startup.
    if (typeof setImmediate === "function") {
      pending.handleType = "immediate";
      pending.handle = setImmediate(run);
    } else {
      pending.handleType = "timeout";
      pending.handle = setTimeout(run, 0);
    }
  }

  createWorkspace(title) {
    const explicitTitle = workspaceTitle(title, "");
    const workspace = this.newWorkspace(explicitTitle || this.generatedWorkspaceTitle());
    workspace.activePanelId = workspace.panels[0]?.id || null;
    this.state.workspaces.push(workspace);
    this.state.activeWorkspaceId = workspace.id;
    this.persistAndBroadcast();
    this.scheduleTerminalPrewarm(workspace.panels[0]);
    return workspace;
  }

  createWorkspaceFromOptions(options = {}) {
    const hasRequestedCwd = Boolean(String(options.cwd || "").trim());
    const cwd = sanitizeDirectoryPath(options.cwd);
    const explicitTitle = workspaceTitle(options.title, "");
    const generatedTitleBase = hasRequestedCwd ? path.basename(cwd) : "Workspace";
    const title = explicitTitle || this.generatedWorkspaceTitle(generatedTitleBase || "Workspace");
    const workspace = this.newWorkspace(title, { cwd });
    workspace.activePanelId = workspace.panels[0]?.id || null;
    this.state.workspaces.push(workspace);
    this.state.activeWorkspaceId = workspace.id;
    this.persistAndBroadcast();
    this.scheduleTerminalPrewarm(workspace.panels[0]);
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
    this.scheduleTerminalPrewarm(panel);
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
      if (title) {
        found.panel.title = title.slice(0, 80);
        found.panel.titleLocked = true;
      }
    }
    if (Object.hasOwn(updates, "color")) {
      const color = String(updates.color || "").trim();
      found.panel.color = isSafeColorValue(color) ? color : "";
    }
    if (updates.direction === "down" || updates.direction === "right") {
      found.workspace.splitDirection = updates.direction;
    }
    if (Object.hasOwn(updates, "url") && found.panel.type === "browser") {
      found.panel.url = sanitizeBrowserUrl(updates.url, found.panel.url || defaultBrowserHomeUrl);
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
    if (!found.panel.titleLocked) found.panel.title = "Terminal";
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
    const terminal = this.ensureTerminalProcess(found.panel);
    terminal.write(String(text || ""));
    return true;
  }

  persistAndBroadcast() {
    if (this.terminalMetadataTimer) {
      clearTimeout(this.terminalMetadataTimer);
      this.terminalMetadataTimer = null;
    }
    this.persistSession();
    this.broadcastState();
  }

  scheduleTerminalMetadataBroadcast() {
    if (this.terminalMetadataTimer) clearTimeout(this.terminalMetadataTimer);
    this.terminalMetadataTimer = setTimeout(() => {
      this.terminalMetadataTimer = null;
      this.persistAndBroadcast();
    }, terminalMetadataBroadcastDelayMs);
  }

  broadcastState() {
    const payload = JSON.stringify({ type: "state", state: this.serializedState() });
    for (const socket of this.eventSockets) {
      if (socket.readyState === WebSocket.OPEN) socket.send(payload);
    }
  }

  requestToken(request, url) {
    const headerToken = request.headers["x-local-token"];
    if (Array.isArray(headerToken)) return headerToken[0] || "";
    return String(headerToken || url.searchParams.get("token") || "");
  }

  requestHasValidToken(request, url) {
    return tokensMatch(this.launchToken, this.requestToken(request, url));
  }

  requestHasAllowedOrigin(request) {
    const origin = request.headers.origin;
    if (!origin) return true;
    const host = request.headers.host;
    return origin === `http://${host}`;
  }

  async handleApi(request, response, url) {
    if (!this.requestHasAllowedOrigin(request)) {
      writeJSON(response, 403, { error: "forbidden_origin" });
      return;
    }
    if (!this.requestHasValidToken(request, url)) {
      writeJSON(response, 401, { error: "unauthorized" });
      return;
    }
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
      const bodyTooLarge = error instanceof RequestBodyTooLargeError;
      const badRequest = error instanceof SyntaxError;
      if (!badRequest && !bodyTooLarge) console.error(error);
      writeJSON(response, bodyTooLarge ? 413 : badRequest ? 400 : 500, {
        error: bodyTooLarge ? "request_too_large" : badRequest ? "invalid_request" : "internal_error"
      });
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
    if (!this.requestHasAllowedOrigin(request)) {
      response.writeHead(403);
      response.end("Forbidden");
      return;
    }
    if (!this.requestHasValidToken(request, url)) {
      response.writeHead(401);
      response.end("Unauthorized");
      return;
    }
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
    if (!this.requestHasAllowedOrigin(request) || !this.requestHasValidToken(request, url)) {
      socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
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
        const terminal = this.ensureTerminalProcess(found.panel);
        terminal.attach(ws);
        return;
      }
      ws.close();
    });
  }

  listen(port = null) {
    const requestedPort = port === null || port === undefined
      ? sanitizeRendererPort(this.state.rendererPort)
      : sanitizeRendererPort(port);
    return this.listenOnPort(requestedPort || 0).catch((error) => {
      if (requestedPort > 0 && error?.code === "EADDRINUSE") {
        try { this.server?.close(); } catch {}
        this.server = null;
        return this.listenOnPort(0);
      }
      throw error;
    });
  }

  listenOnPort(port) {
    return new Promise((resolve, reject) => {
      const server = http.createServer((request, response) => {
        const url = new URL(request.url, "http://127.0.0.1");
        if (url.pathname.startsWith("/api/")) {
          this.handleApi(request, response, url);
        } else if (url.pathname === "/_cmux/local-image") {
          this.serveLocalImage(request, response, url);
        } else {
          this.serveStatic(request, response, url);
        }
      });
      this.server = server;
      const onError = (error) => reject(error);
      server.on("upgrade", (request, socket, head) => this.handleUpgrade(request, socket, head));
      server.once("error", onError);
      server.listen(port, "127.0.0.1", async () => {
        server.removeListener("error", onError);
        server.on("error", (error) => console.error(error));
        try {
          await this.startPipeServer();
        } catch (error) {
          server.close();
          reject(error);
          return;
        }
        const address = server.address();
        this.state.rendererPort = address.port;
        this.persistSession();
        resolve({
          port: address.port,
          url: `http://127.0.0.1:${address.port}/`,
          pipeName: this.pipeName,
          launchToken: this.launchToken,
          ptyAvailable: this.ptyAvailable
        });
      });
    });
  }

  startPipeServer() {
    return new Promise((resolve, reject) => {
      if (process.platform !== "win32" && fs.existsSync(this.pipeName)) {
        fs.unlinkSync(this.pipeName);
      }
      this.pipeServer = net.createServer((socket) => {
        let buffer = "";
        let bufferedBytes = 0;
        let authContext = null;
        socket.on("data", (chunk) => {
          if (bufferedBytes + chunk.length > pipeReadBufferLimitBytes) {
            socket.destroy();
            return;
          }
          buffer += chunk.toString("utf8");
          bufferedBytes += chunk.length;
          let index = buffer.indexOf("\n");
          while (index >= 0) {
            const line = buffer.slice(0, index).trim();
            buffer = buffer.slice(index + 1);
            bufferedBytes = Buffer.byteLength(buffer);
            if (!authContext) {
              authContext = this.authenticatePipeLine(line);
              if (authContext) {
                index = buffer.indexOf("\n");
                continue;
              }
              socket.write("ERROR unauthorized\n");
              socket.end();
              return;
            }
            this.handlePipeLine(line, authContext).then((reply) => {
              socket.write(reply + "\n");
            }).catch((error) => {
              console.error(error);
              socket.write(JSON.stringify({ ok: false, error: "internal_error" }) + "\n");
            });
            index = buffer.indexOf("\n");
          }
        });
      });
      this.pipeServer.once("error", reject);
      this.pipeServer.once("listening", () => {
        this.pipeServer.removeListener("error", reject);
        resolve();
      });
      this.pipeServer.listen(this.pipeName);
    });
  }

  authenticatePipeLine(line) {
    if (!line) return null;
    if (tokensMatch(this.launchToken, line)) return { scope: "full" };
    if (line.startsWith("auth ")) {
      return tokensMatch(this.launchToken, line.slice(5).trim()) ? { scope: "full" } : null;
    }
    const panelAuth = line.match(/^auth-panel\s+(\S+)\s+(\S+)$/);
    if (panelAuth) return this.authenticatePanelPipe(panelAuth[1], panelAuth[2]);
    if (!line.startsWith("{")) return null;
    try {
      const request = JSON.parse(line);
      if (tokensMatch(this.launchToken, request.token || request.params?.token)) return { scope: "full" };
      return this.authenticatePanelPipe(request.params?.panelId, request.params?.panelToken);
    } catch {
      return null;
    }
  }

  authenticatePanelPipe(panelId, panelToken) {
    const terminal = this.terminals.get(String(panelId || ""));
    if (!terminal || terminal.closed || !terminal.panelToken) return null;
    if (!tokensMatch(terminal.panelToken, panelToken)) return null;
    return { scope: "panel", panelId: terminal.panel.id };
  }

  async handlePipeLine(line, authContext = { scope: "full" }) {
    if (!line) return "ERROR empty command";
    if (authContext.scope === "panel") return this.handlePanelPipeLine(line, authContext.panelId);
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

  async handlePanelPipeLine(line, panelId) {
    if (line.startsWith("{")) {
      const request = JSON.parse(line);
      if (request.method === "system.ping") {
        return JSON.stringify({ jsonrpc: "2.0", id: request.id ?? null, result: { ok: true } });
      }
      if (request.method === "terminal.send") {
        const result = { ok: this.sendInput(String(request.params?.text || ""), panelId) };
        return JSON.stringify({ jsonrpc: "2.0", id: request.id ?? null, result });
      }
      return JSON.stringify({ jsonrpc: "2.0", id: request.id ?? null, error: { code: 403, message: "forbidden" } });
    }
    const [command, ...args] = line.split(/\s+/);
    switch (command) {
      case "ping":
        return "OK";
      case "send":
        return this.sendInput(`${args.join(" ")}\r`, panelId) ? "OK" : "ERROR no terminal";
      default:
        return `ERROR unauthorized command: ${command}`;
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
    this.closed = true;
    if (this.terminalMetadataTimer) {
      clearTimeout(this.terminalMetadataTimer);
      this.terminalMetadataTimer = null;
    }
    for (const pending of this.pendingTerminalPrewarms.values()) {
      pending.canceled = true;
      if (!pending.handle) continue;
      if (pending.handleType === "timeout") clearTimeout(pending.handle);
      else clearImmediate(pending.handle);
    }
    this.pendingTerminalPrewarms.clear();
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
