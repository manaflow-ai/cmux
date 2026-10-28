// One eval sample's cmux: an ephemeral headless session daemon, its MCP server
// (`cmux mcp serve`, code mode or --all-tools) and the CLI pointed at it. The
// agent's `cmux_exec` scripts and `cmux ...` shell commands run here for real;
// nothing reaches the user's sessions or app (no app socket, scrubbed env).
import { execFile, spawn } from "node:child_process";
import { createServer } from "node:net";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { gunzipSync } from "node:zlib";
import { columnsOf } from "../agent-evals/snapshot.mjs";

/** The app's action catalogue, captured from a real app (templates/app.json.gz). */
const APP = JSON.parse(gunzipSync(readFileSync(new URL("./templates/app.json.gz", import.meta.url))).toString());

const pexec = promisify(execFile);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function openSession({ cli, name, dir, allTools, setup = [], noApp = false }) {
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
  const daemon = spawn(cli, ["daemon", "start", "--session", name, "--socket", socket, "--ephemeral", "--headless"], {
    env, cwd: work, stdio: ["ignore", "ignore", "ignore"], detached: true,
  });
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

  const app = noApp ? null : await standInApp(env.CMUX_SOCKET_PATH, cmux, origin);

  // The agent runs in the origin terminal, so `current` is its workspace and pane.
  // A terminal reaches its session through CMUX_TUI_SOCKET, not --session (which turns
  // `current` into the focused object).
  const agentEnv = { ...env, CMUX_TUI_SOCKET: socket, CMUX_TUI_TERMINAL_ID: origin.terminal_id };
  const mcp = new McpClient(cli, ["mcp", "serve", ...(allTools ? ["--all-tools"] : [])], agentEnv, work);
  const init = await mcp.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "cmux-tool-evals", version: "1" } });
  mcp.notify("notifications/initialized");
  const { tools } = await mcp.request("tools/list", {});

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
    app?.close();
    await pexec(cli, ["daemon", "stop", "--socket", socket, "--end-terminals", "--force"], { env }).catch(() => {});
    try { process.kill(-daemon.pid, "SIGTERM"); } catch {}
    for (const f of readdirSync("/tmp/cte")) if (f.startsWith(`${name}.sock`)) rmSync(join("/tmp/cte", f), { force: true });
    rmSync(work, { recursive: true, force: true });
  };
  return { name, env: agentEnv, socket, cmux, mcp, tools, instructions: init.instructions ?? "", origin, aliases, shell, work, close };
}

async function runSetup(cmux, setup, origin, work) {
  const aliases = {};
  for (const step of setup) {
    if (step.op === "workspace") {
      const r = await cmux(["workspace", "create", "--name", step.name, "--cwd", work]);
      if (step.alias) aliases[step.alias] = r.workspace_id;
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

/**
 * The app's place-and-focus answers, without an app: `system.identify` names the
 * agent's own terminal (as the app does for a chat in it) and `snapshot.get` the
 * daemon's focus. `action.list` and `system.capabilities` replay a real app's catalogue,
 * so the app's tools are listed and searched as in the app. Every other app method fails as an app that cannot do it would.
 */
async function standInApp(path, cmux, origin) {
  rmSync(path, { force: true });
  const answer = async (method) => {
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
      return { topology: { focus: { workspace: ws.id, pane: pane?.id } } };
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
        const reply = await answer(msg.method).then((result) => ({ id: msg.id, ok: true, result }), (error) => ({ id: msg.id, ok: false, error }));
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
