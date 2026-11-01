// One eval sample's cmux: an ephemeral headless session daemon, its MCP server
// (`cmux mcp serve`, code mode or --all-tools) and the CLI pointed at it. The
// agent's `cmux_exec` scripts and `cmux ...` shell commands run here for real;
// nothing reaches the user's sessions or app (no app socket, scrubbed env).
import { execFile, spawn } from "node:child_process";
import { createServer } from "node:net";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { gunzipSync } from "node:zlib";
import { columnsOf } from "../agent-evals/snapshot.mjs";

/** The app's action catalogue, captured from a real app (templates/app.json.gz). */
const APP = JSON.parse(gunzipSync(readFileSync(new URL("./templates/app.json.gz", import.meta.url))).toString());

const pexec = promisify(execFile);
/** The tools the hybrid surface lists directly: the common-tool sheet of cmux_exec's description. */
export const CORE_TOOLS = [
  "workspace_list", "workspace_get", "pane_list", "tab_list", "terminal_list", "terminal_get",
  "tab_create_terminal", "pane_split", "terminal_input_write", "terminal_wait", "terminal_screen_read",
  "terminal_history_read", "tab_rename", "tab_close", "tab_focus", "workspace_rename", "tab_group_create",
  "workspace_group_create", "workspace_place", "workspace_status_set", "notification_create",
];

/** The stub helper agent of agent-evals' subagents-right: records the terminal it ran in. */
export const evalAgentStub = (dir) =>
  `#!/bin/bash\nrole=""\nwhile [ $# -gt 0 ]; do case "$1" in --role) role="$2"; shift 2;; --role=*) role="\${1#--role=}"; shift;; *) shift;; esac; done\n[ -z "$role" ] && { echo "usage: cmux-eval-agent --role NAME" >&2; exit 2; }\necho "\${CMUX_TUI_TERMINAL_ID:-unknown}" > ${JSON.stringify(join(dir, "markers"))}/$role\necho "agent $role ready"\nexec sleep 3600\n`;

/** ssh to the daemon's host. No ControlPersist: its background master keeps the first
 * caller's output pipe open, so that call never returned. */
export const SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15"];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * `remote` runs the session daemon on another host ({host, cli}: an ssh host and its cmux
 * binary) and forwards its socket here, so its terminals use that host's PTYs (a Mac caps
 * them at 511, and the person's own cmux holds most). Clients, the MCP server and the
 * agent stay on this machine.
 */
export async function openSession({ cli, name, dir, allTools, setup = [], noApp = false, remote = null }) {
  mkdirSync(dir, { recursive: true });
  const work = mkdtempSync(join(tmpdir(), "cmux-tool-eval-"));
  const env = {};
  for (const [k, v] of Object.entries(process.env)) if (!/^(CMUX|ACPMUX|MUX)[A-Z0-9_]*$/.test(k)) env[k] = v;
  env.CMUX_NEXT_CONFIG_FILE = join(dir, "cmux-next.json");
  env.CMUX_SOCKET_PATH = noApp ? join(dir, "no-app.sock") : `/tmp/cte/${name}-app.sock`;
  // Terminals the daemon starts find the eval's `cmux` shim and helper stubs first.
  env.PATH = `${join(dir, "bin")}:${env.PATH}`;
  writeFileSync(env.CMUX_NEXT_CONFIG_FILE, JSON.stringify({ mcp: { enabled: true } }));

  // A short socket path of our own: a Unix socket path must stay under 104 bytes.
  mkdirSync("/tmp/cte", { recursive: true });
  const socket = `/tmp/cte/${name}.sock`;
  const cmux = async (args, { json = true } = {}) => {
    const { stdout } = await pexec(cli, ["--socket", socket, ...(json ? ["--json"] : []), ...args], { env, maxBuffer: 64 << 20 });
    if (!json) return stdout;
    const parsed = JSON.parse(stdout);
    return parsed && typeof parsed === "object" && "value" in parsed && "revision" in parsed ? parsed.value : parsed;
  };
  let daemon;
  let launcher = null;
  let remotePidFile = null;
  const ssh = remote && ((args) => pexec("ssh", [...SSH_OPTS, remote.host, ...args], { maxBuffer: 16 << 20 }));
  if (remote) {
    // The same paths there: the daemon's cwd, the stub helpers and the markers they write.
    const stub = Buffer.from(evalAgentStub(dir)).toString("base64");
    const q = JSON.stringify;
    const stubPath = join(dir, "bin", "cmux-eval-agent");
    // setsid makes the daemon its own process group; its PID (the group's id) is kept beside the
    // socket so the stop below signals that group, never a process found by name.
    remotePidFile = `${socket}.pid`;
    // Fire and forget: the remote shell outlives its backgrounded daemon over Tailscale ssh, so
    // waiting on it never returned. The ready loop below waits for the daemon's socket.
    launcher = spawn("ssh", [...SSH_OPTS, "-n", remote.host, `mkdir -p /tmp/cte ${q(work)} ${q(join(dir, "bin"))} ${q(join(dir, "markers"))} && echo ${stub} | base64 -d > ${q(stubPath)} && chmod +x ${q(stubPath)} && cd ${q(work)} && PATH=${q(join(dir, "bin"))}:$PATH setsid nohup ${remote.cli} daemon start --session ${name} --socket ${socket} --ephemeral --headless < /dev/null > /dev/null 2>&1 & echo $! > ${q(remotePidFile)}`], { stdio: "ignore", detached: true });
    launcher.unref();
    rmSync(socket, { force: true });
    daemon = spawn("ssh", [...SSH_OPTS, "-o", "StreamLocalBindUnlink=yes", "-N", "-L", `${socket}:${socket}`, remote.host], { stdio: "ignore", detached: true });
  } else {
    daemon = spawn(cli, ["daemon", "start", "--session", name, "--socket", socket, "--ephemeral", "--headless"], {
      env, cwd: work, stdio: ["ignore", "ignore", "ignore"], detached: true,
    });
  }
  // Stops this sample's daemon and its terminals. A failed open stops it too: an open that
  // threw after the spawn left the daemon running (1,115 daemons after one overloaded panel).
  const stopDaemon = async () => {
    await pexec(cli, ["daemon", "stop", "--socket", socket, "--end-terminals", "--force"], { env }).catch(() => {});
    // A remote daemon outlives a stop sent through a closed forward (1,000+ daemons of old
    // runs were still up on the remote host, 2026-10-31): stop it there by the process group the
    // launcher recorded.
    if (remote) {
      const stop = `${remote.cli} daemon stop --socket ${socket} --end-terminals --force; p=$(cat ${JSON.stringify(remotePidFile)} 2>/dev/null) && kill -TERM -- -"$p" 2>/dev/null; true`;
      await pexec("ssh", [...SSH_OPTS, "-n", remote.host, stop]).catch(() => {});
    }
    try { process.kill(-daemon.pid, "SIGTERM"); } catch {}
    try { if (launcher) process.kill(-launcher.pid, "SIGTERM"); } catch {}
    for (const f of readdirSync("/tmp/cte")) if (f.startsWith(`${name}.sock`)) rmSync(join("/tmp/cte", f), { force: true });
    rmSync(work, { recursive: true, force: true });
    if (remote) await ssh([`rm -rf /tmp/cte/${name}.sock* ${JSON.stringify(work)} ${JSON.stringify(dir)}`]).catch(() => {});
  };
  /**
   * The `cmux mcp serve` command for this session: local, or on the daemon's host over ssh
   * stdio with the stand-in app's socket forwarded back, so the MCP server is that host's
   * build (a Linux build of any commit, no Mac build needed).
   */
  const mcpCommand = (serveArgs) => {
    if (!remote) return { command: cli, args: ["mcp", "serve", ...serveArgs] };
    const remoteEnv = [
      `CMUX_TUI_SOCKET=${socket}`, `CMUX_TUI_TERMINAL_ID=${agentEnvRef.CMUX_TUI_TERMINAL_ID}`,
      `CMUX_SOCKET_PATH=${env.CMUX_SOCKET_PATH}`, `CMUX_NEXT_CONFIG_FILE=${env.CMUX_NEXT_CONFIG_FILE}`,
    ];
    const serve = ["env", ...remoteEnv, remote.cli, "mcp", "serve", ...serveArgs];
    if (noApp) return { command: "ssh", args: [...SSH_OPTS, remote.host, ...serve] };
    // Tailscale SSH creates a forwarded socket as root, mode 0600, so the MCP server (this
    // user, which also checks the peer's uid) could not reach the stand-in app: every
    // remote run so far saw no app. The forward goes to `<app>.fwd`, opened with sudo, and
    // a relay of this user listens at the app path until the MCP server exits.
    const app = env.CMUX_SOCKET_PATH;
    const sq = (text) => `'${String(text).replaceAll("'", "'\\''")}'`;
    const relay = `import base64;exec(base64.b64decode("${Buffer.from(APP_RELAY).toString("base64")}"))`;
    const prelude = `sudo -n chmod 666 ${sq(`${app}.fwd`)} && (setsid python3 -c ${sq(relay)} ${sq(app)} ${sq(`${app}.fwd`)} $$ </dev/null >/dev/null 2>&1 &) && sleep 0.3 && exec`;
    const forward = ["-o", "StreamLocalBindUnlink=yes", "-R", `${app}.fwd:${app}`];
    return { command: "ssh", args: [...SSH_OPTS, ...forward, remote.host, prelude, ...serve.map(sq)] };
  };
  const agentEnvRef = {};
  /** The markers the stub helpers wrote (on the daemon's host). */
  const markers = async () => {
    if (!remote) return null;
    const { stdout } = await ssh([`cd ${JSON.stringify(join(dir, "markers"))} 2>/dev/null && for f in *; do [ -f "$f" ] && printf '%s\t%s\n' "$f" "$(cat "$f")"; done; true`]).catch(() => ({ stdout: "" }));
    return Object.fromEntries(stdout.split("\n").filter(Boolean).map((l) => l.split("\t")));
  };
  let mcp = null;
  let directMcp = null;
  let app = null;
  try {
    let ready = false;
    for (let i = 0; i < 75 && !ready; i++) {
      try { await cmux(["workspace", "list"]); ready = true; } catch { await sleep(200); }
    }
    if (!ready) throw new Error(`daemon ${name} did not start`);
    const home = await cmux(["workspace", "create", "--name", "home", "--cwd", work]);
    const origin = { workspace_id: home.workspace_id, screen_id: home.screen_id, pane_id: home.pane_id, tab_id: home.tab_id, terminal_id: home.terminal_id };
    const aliases = await runSetup(cmux, setup, origin, work);
    await cmux(["workspace", origin.workspace_id, "focus"]);
    await cmux(["pane", origin.pane_id, "focus"]);

    app = noApp ? null : await standInApp(env.CMUX_SOCKET_PATH, cmux, origin, join(dir, "app-calls.jsonl"));

    // The agent runs in the origin terminal, so `current` is its workspace and pane.
    // A terminal reaches its session through CMUX_TUI_SOCKET, not --session (which turns
    // `current` into the focused object).
    const agentEnv = { ...env, CMUX_TUI_SOCKET: socket, CMUX_TUI_TERMINAL_ID: origin.terminal_id };
    agentEnvRef.CMUX_TUI_TERMINAL_ID = origin.terminal_id;
    // The MCP server reads this file on the daemon's host. Write it there and read it
    // back before the server starts: a missing file serves "the MCP server is off", and
    // the agent then falls back to the shell (h4 panel: 15 samples, Opus 33 -> 25).
    if (remote) {
      const config = JSON.stringify(env.CMUX_NEXT_CONFIG_FILE);
      let written = false;
      for (let attempt = 0; attempt < 5 && !written; attempt++) {
        const { stdout } = await ssh([`mkdir -p ${JSON.stringify(dir)} && echo '{"mcp":{"enabled":true}}' > ${config} && cat ${config}`]).catch(() => ({ stdout: "" }));
        written = stdout.includes('"enabled":true');
        if (!written) await sleep(1000 * (attempt + 1));
      }
      if (!written) throw new Error(`could not write the MCP settings file on ${remote.host}`);
    }
    const start = async (args) => {
      const { command, args: argv } = mcpCommand(args);
      const client = new McpClient(command, argv, agentEnv, work);
      const init = await client.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "cmux-tool-evals", version: "1" } });
      client.notify("notifications/initialized");
      return { client, init, tools: (await client.request("tools/list", {})).tools };
    };
    // `allTools`: true lists every tool; "hybrid" lists cmux_exec plus the CORE tools directly
    // (a second server with --all-tools answers those).
    const main = await start(allTools === true ? ["--all-tools"] : []);
    mcp = main.client;
    const init = main.init;
    let tools = main.tools;
    if (allTools === "hybrid") {
      const direct = await start(["--all-tools"]);
      directMcp = direct.client;
      tools = [...tools, ...direct.tools.filter((t) => CORE_TOOLS.includes(t.name))];
    }
    /** The server that answers a tool. */
    const route = (name) => (directMcp && name !== "cmux_exec" && name !== "cmux_docs" ? directMcp : mcp);

    /** Runs one agent shell command whose first word is `cmux`, against this session. */
    const shell = async (argv) => {
      try {
        const { stdout, stderr } = await pexec(cli, argv, { env: agentEnv, cwd: work, maxBuffer: 16 << 20, timeout: 60_000 });
        return { ok: true, output: `${stdout}${stderr}` };
      } catch (e) {
        return { ok: false, output: `${e.stdout ?? ""}${e.stderr ?? ""}`.trim() || String(e.message) };
      }
    };

    const close = async () => {
      mcp.close();
      directMcp?.close();
      app?.close();
      await stopDaemon();
    };
    return { name, env: agentEnv, socket, cmux, mcp, route, markers, mcpCommand, tools, instructions: init.instructions ?? "", origin, aliases, shell, work, close };
  } catch (error) {
    mcp?.close();
    directMcp?.close();
    app?.close();
    await stopDaemon();
    throw error;
  }
}

async function runSetup(cmux, setup, origin, work) {
  const aliases = {};
  for (const step of setup) {
    if (step.op === "workspace") {
      const r = await cmux(["workspace", "create", "--name", step.name, "--cwd", work]);
      if (step.alias) aliases[step.alias] = r.workspace_id;
    } else if (step.op === "dock") {
      // Pins the column of `pane` (an alias) to `edge` (default right): a sticky column.
      const pane = aliases[step.pane] ?? step.pane;
      const layout = await cmux(["screen", origin.screen_id, "layout", "export"]);
      const column = columnsOf(layout).find((c) => c.pane_ids.includes(pane))?.column_id;
      if (column) await cmux(["screen", origin.screen_id, "column", column, "update", "--dock", "true", "--edge", step.edge ?? "right"]);
    } else if (step.op === "split-right") {
      const r = await cmux(["pane", origin.pane_id, "split", "--right", "--viewport-width", "0.5"]);
      if (step.alias) aliases[step.alias] = r.pane_id;
      if (step.name) await cmux(["tab", r.tab_id, "rename", step.name]);
      if (step.run) await cmux(["terminal", r.terminal_id, "write", "--text", `${step.run}\n`]);
    } else if (step.op === "tab") {
      const r = await cmux(["tab", "create", "terminal", "--pane", aliases[step.pane] ?? step.pane]);
      if (step.alias) aliases[step.alias] = r.tab_id;
      if (step.name) await cmux(["tab", r.tab_id, "rename", step.name]);
      if (step.run) await cmux(["terminal", r.terminal_id, "write", "--text", `${step.run}\n`]);
    } else {
      throw new Error(`unknown setup op ${step.op}`);
    }
  }
  // Setup commands print before the agent's first look (a fast agent read a
  // terminal before its `echo` ran). Harness-only settle time.
  if (setup.length) await sleep(setup.some((step) => step.run) ? 2500 : 800);
  return aliases;
}

/** A unix socket relay (argv: listen path, target path, owner pid): one thread pair per
 * connection; it exits when the owner process does. */
const APP_RELAY = `import os,socket,sys,threading,time
listen,target,owner=sys.argv[1],sys.argv[2],int(sys.argv[3])
try: os.unlink(listen)
except OSError: pass
srv=socket.socket(socket.AF_UNIX); srv.bind(listen); os.chmod(listen,0o600); srv.listen(16)
def pipe(a,b):
  try:
    while True:
      d=a.recv(65536)
      if not d: break
      b.sendall(d)
  except OSError: pass
  for s in (a,b):
    try: s.shutdown(socket.SHUT_RDWR)
    except OSError: pass
def serve():
  while True:
    c,_=srv.accept(); t=socket.socket(socket.AF_UNIX)
    try: t.connect(target)
    except OSError: c.close(); continue
    threading.Thread(target=pipe,args=(c,t),daemon=True).start(); threading.Thread(target=pipe,args=(t,c),daemon=True).start()
threading.Thread(target=serve,daemon=True).start()
while True:
  time.sleep(2)
  try: os.kill(owner,0)
  except OSError: break
try: os.unlink(listen)
except OSError: pass`;

/** The app actions that open a viewer tab (a file, a diff, a page), by id and CLI name. */
const OPEN_ACTIONS = new Map([
  ["file.open", "file"], ["file open", "file"],
  ["openDiffViewer", "diff"], ["browser open-diff-viewer", "diff"],
  ["palette.openDirectoryDiffViewer", "diff"], ["browser open-directory-diff-viewer", "diff"],
  ["openBrowser", "page"], ["tab new-browser", "page"],
  ["openBrowser.webkit", "page"], ["tab new-webkit", "page"],
  ["openBrowser.chromium", "page"], ["tab new-chromium", "page"],
]);

/**
 * The app's place-and-focus answers, without an app: `system.identify` names the
 * agent's own terminal (as the app does for a chat in it) and `snapshot.get` the
 * daemon's focus. `action.list` and `system.capabilities` replay a real app's catalogue,
 * so the app's tools are listed and searched as in the app.
 *
 * The app's open actions (a file, a diff, a page: OPEN_ACTIONS and `browser.open_split`)
 * run as the app places them: a tab in the `target` pane (a pane, or a tab's pane), else
 * the focused pane; a page with no workspace beside the chat. The tab is a terminal named
 * for what it shows (headless renders no viewer), and every open is recorded in `log` for
 * the grader. Every other app method fails as an app that cannot do it would.
 */
async function standInApp(path, cmux, origin, log) {
  rmSync(path, { force: true });
  const paneOf = async (target) => {
    const id = String(target ?? "").replace(/^(pane|tab|workspace):/, "").replace(/^[\w.-]+:(?=(pane|tab|ws)_)/, "");
    if (id.startsWith("pane_")) return id;
    if (id.startsWith("tab_")) return (await cmux(["tab", id, "show"]))?.pane_id ?? null;
    if (id.startsWith("ws_")) return workspacePane(id);
    return null;
  };
  // A named workspace's pane: its focused one, else its first (the app's default pane).
  const workspacePane = async (workspace) => {
    const panes = await cmux(["pane", "list", "--workspace", workspace]);
    const items = panes?.items ?? panes ?? [];
    return (items.find((p) => p.focused) ?? items[0])?.id ?? null;
  };
  const besidePane = async () => {
    const layout = await cmux(["screen", origin.screen_id, "layout", "export"]);
    const columns = columnsOf(layout);
    const mine = columns.findIndex((c) => c.pane_ids.includes(origin.pane_id));
    const right = mine >= 0 ? columns.slice(mine + 1).find((c) => !c.docked) : null;
    if (right?.pane_ids[0]) return right.pane_ids[0];
    return (await cmux(["pane", origin.pane_id, "split", "--right"]))?.pane_id ?? origin.pane_id;
  };
  const open = async (kind, what, pane, request) => {
    const label = `[${kind}] ${what}`.slice(0, 80);
    const created = await cmux(["tab", "create", "terminal", "--pane", pane, "--name", label]);
    // `focus: true` (the run's or the open's) shows the new tab, as the app does.
    if (request.focus === true && created?.tab_id) await cmux(["tab", created.tab_id, "focus"]);
    appendFileSync(log, `${JSON.stringify({ kind, what, pane, tab: created?.tab_id, request })}\n`);
    return { created: { tab_id: created?.tab_id, pane_id: pane }, state: "done" };
  };
  const answer = async ({ method, params = {} }) => {
    if (method === "action.run" && OPEN_ACTIONS.has(params.action)) {
      const kind = OPEN_ACTIONS.get(params.action);
      const args = params.args ?? {};
      const what = args.path ?? args.url ?? (kind === "diff" ? "changes" : "");
      // The app's own refusals: a file or diff path must be absolute (AgentHandlers.openFile,
      // ViewerHandlers), and a page takes a tab target (TabActionCatalog `targets: [.tab]`).
      if (kind !== "page" && args.path != null && !String(args.path).startsWith("/")) {
        throw { code: "invalid_argument", message: `path must be absolute: ${args.path}` };
      }
      if (kind === "page" && params.target != null && !/(^|:)tab_/.test(String(params.target))) {
        throw { code: "invalid_argument", message: `No tab matches ${params.target}` };
      }
      const pane = (await paneOf(params.target)) ?? origin.pane_id;
      return open(kind, what, pane, { method, action: params.action, args, target: params.target ?? null, focus: params.focus === true || args.focus === true });
    }
    if (method === "browser.open_split") {
      const pane = params.workspace_id ? await workspacePane(params.workspace_id) : await besidePane();
      return open("page", params.url ?? "", pane ?? origin.pane_id, { method, url: params.url, focus: params.focus === true });
    }
    if (method === "system.identify") {
      const caller = { workspace: origin.workspace_id, screen: origin.screen_id, pane: origin.pane_id, tab: origin.tab_id, terminal_id: origin.terminal_id };
      // `beside`: the first undocked pane in the column right of the chat's, as the app answers.
      const layout = await cmux(["screen", origin.screen_id, "layout", "export"]);
      const columns = columnsOf(layout);
      const mine = columns.findIndex((c) => c.pane_ids.includes(origin.pane_id));
      const right = mine >= 0 ? columns.slice(mine + 1).find((c) => !c.docked) : null;
      return { caller, ...(right?.pane_ids[0] ? { beside: { pane: right.pane_ids[0] } } : {}) };
    }
    if (method === "snapshot.get") {
      const workspaces = await cmux(["workspace", "list"]);
      const ws = workspaces.find((w) => w.focused) ?? workspaces[0];
      const panes = (await cmux(["pane", "list", "--workspace", ws.id]));
      const pane = (panes.items ?? panes).find((p) => p.focused);
      // The app's focus names every level, the tab too.
      const tabs = pane ? await cmux(["tab", "list", "--pane", pane.id]) : [];
      const tab = (tabs.items ?? tabs).find((t) => t.focused) ?? (tabs.items ?? tabs)[0];
      return { topology: { focus: { workspace: ws.id, pane: pane?.id, tab: tab?.id } } };
    }
    if (method === "action.list" || method === "system.capabilities") return APP[method];
    throw { code: "app.unavailable", message: `the cmux app does not answer ${method} in this session; workspace, pane, tab and terminal tools work` };
  };
  const server = createServer((socket) => {
    let buf = "";
    socket.on("data", async (chunk) => {
      buf += chunk;
      for (let i; (i = buf.indexOf("\n")) >= 0; ) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }
        const reply = await answer(msg).then((result) => ({ id: msg.id, ok: true, result }), (error) => ({ id: msg.id, ok: false, error }));
        socket.write(`${JSON.stringify(reply)}\n`);
      }
    });
    socket.on("error", () => {});
  });
  await new Promise((resolve) => server.listen(path, resolve));
  return server;
}

/** A line-delimited JSON-RPC client for one `cmux mcp serve` process. */
class McpClient {
  constructor(cli, args, env, cwd) {
    this.next = 1;
    this.waiting = new Map();
    this.proc = spawn(cli, args, { env, cwd, stdio: ["pipe", "pipe", "ignore"] });
    let buf = "";
    this.proc.stdout.on("data", (chunk) => {
      buf += chunk;
      for (let i; (i = buf.indexOf("\n")) >= 0; ) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        if (!line.trim()) continue;
        const msg = JSON.parse(line);
        const w = this.waiting.get(msg.id);
        if (!w) continue;
        this.waiting.delete(msg.id);
        msg.error ? w.reject(new Error(msg.error.message)) : w.resolve(msg.result);
      }
    });
  }
  request(method, params) {
    const id = this.next++;
    this.proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    return new Promise((resolve, reject) => this.waiting.set(id, { resolve, reject }));
  }
  notify(method) {
    this.proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method })}\n`);
  }
  close() {
    this.proc.kill();
  }
}
