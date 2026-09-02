#!/usr/bin/env bun
// cmux relay dashboard: lists machines reachable through the native relay,
// opens PTYs on them through `cmux-tui remote ...`, and renders them in the
// browser with ghostty-web. Two machine sources:
//   - the local relay lab (scripts/relay-lab.sh), read from CMUX_RELAY_LAB_DIR
//   - cmux Cloud VMs from a web API (CMUX_DASHBOARD_API_URL), signed in with the
//     dogfood Stack credentials from ~/.secrets/cmuxterm-dev.env
//
//   bun tools/relay-dashboard/server.ts            # http://127.0.0.1:8790
//
// Env: CMUX_RELAY_LAB_DIR, CMUX_TUI_BIN, GHOSTTY_WEB_DIR, CMUX_DASHBOARD_PORT,
//      CMUX_DASHBOARD_API_URL, CMUX_DASHBOARD_STACK_EMAIL/PASSWORD.
import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const tuiRoot = resolve(here, "..", "..");
const PORT = Number(process.env.CMUX_DASHBOARD_PORT ?? 8790);
const TUI = process.env.CMUX_TUI_BIN ?? join(tuiRoot, "target", "debug", "cmux-tui");
const LAB = process.env.CMUX_RELAY_LAB_DIR ?? "/tmp/cmux-relay-lab";
const LAB_SCRIPT = join(tuiRoot, "scripts", "relay-lab.sh");
const STATE = join(homedir(), ".cache", "cmux-relay-dashboard");
mkdirSync(STATE, { recursive: true, mode: 0o700 });

// ---------- ghostty-web assets -------------------------------------------------

function findGhosttyWeb(): string {
  const candidates = [process.env.GHOSTTY_WEB_DIR];
  let dir = tuiRoot;
  for (let i = 0; i < 6; i++) {
    candidates.push(join(dir, "ghostty-web"), join(dir, "node_modules", "ghostty-web"));
    dir = dirname(dir);
  }
  for (const c of candidates) {
    if (c && existsSync(join(c, "dist", "ghostty-web.js")) && existsSync(join(c, "atlas"))) return c;
  }
  throw new Error("ghostty-web checkout not found; set GHOSTTY_WEB_DIR to a checkout with dist/ and atlas/");
}
const GHOSTTY_WEB = findGhosttyWeb();
const WASM = existsSync(join(GHOSTTY_WEB, "dist", "ghostty-vt.wasm"))
  ? join(GHOSTTY_WEB, "dist", "ghostty-vt.wasm")
  : join(GHOSTTY_WEB, "ghostty-vt.wasm");

// ---------- machines ---------------------------------------------------------------

type RelayCredential = { route: string; slot: string; ticketFile?: string; ticketCommand?: string[] };
type Machine = {
  id: string;
  name: string;
  source: "lab" | "cloud";
  routes: string[];
  status: "online" | "offline" | "unknown";
  relays: RelayCredential[];
  stateDir: string;
  inviteFile?: string;
  approve?: () => Promise<void>;
  refreshTickets?: () => Promise<void>;
};

function readLabEnv(): Record<string, string> | null {
  const envPath = join(LAB, "env");
  if (!existsSync(envPath)) return null;
  const out: Record<string, string> = {};
  for (const line of readFileSync(envPath, "utf8").split("\n")) {
    const m = /^([A-Z_]+)=(.*)$/.exec(line.trim());
    if (m) out[m[1]] = m[2];
  }
  return out;
}

async function readyz(port: string): Promise<number> {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/readyz`, { signal: AbortSignal.timeout(1500) });
    return res.status;
  } catch {
    return 0;
  }
}

async function labShards() {
  const env = readLabEnv();
  if (!env) return [];
  const shards = [];
  for (const id of ["a", "b"]) {
    const port = env[`SHARD_${id.toUpperCase()}_PORT`];
    if (!port) continue;
    shards.push({ id, route: `relay+ws://127.0.0.1:${port}`, ready: await readyz(port), controllable: true });
  }
  return shards;
}

function labMachine(): Machine | null {
  const env = readLabEnv();
  if (!env || !existsSync(join(LAB, "client-state"))) return null;
  const relays: RelayCredential[] = [];
  for (const id of ["a", "b"]) {
    const port = env[`SHARD_${id.toUpperCase()}_PORT`];
    const slotFile = join(LAB, `shard-${id}`, "slot");
    if (!port || !existsSync(slotFile)) continue;
    relays.push({
      route: `relay+ws://127.0.0.1:${port}`,
      slot: readFileSync(slotFile, "utf8").trim(),
      ticketCommand: [join(LAB, "bin", "ticket"), id, "connect"],
    });
  }
  return {
    id: "lab",
    name: `relay lab daemon (${hostname()})`,
    source: "lab",
    routes: relays.map((r) => r.route),
    status: existsSync(join(LAB, "admin.sock")) ? "online" : "offline",
    relays,
    stateDir: join(LAB, "client-state"),
  };
}

// ---------- cloud VMs (optional) ------------------------------------------------------

type StackTokens = { access: string; refresh: string };
const API_URL = process.env.CMUX_DASHBOARD_API_URL?.replace(/\/$/, "");
let stackTokens: StackTokens | null = null;
let cloudWarning: string | null = null;

function loadDevSecrets(): { email: string; password: string } | null {
  const email = process.env.CMUX_DASHBOARD_STACK_EMAIL;
  const password = process.env.CMUX_DASHBOARD_STACK_PASSWORD;
  if (email && password) return { email, password };
  for (const file of [join(homedir(), ".secrets", "cmuxterm-dev.env"), join(homedir(), ".secrets", "cmux.env")]) {
    if (!existsSync(file)) continue;
    const env: Record<string, string> = {};
    for (const line of readFileSync(file, "utf8").split("\n")) {
      const m = /^(?:export\s+)?([A-Z_]+)=["']?(.*?)["']?$/.exec(line.trim());
      if (m) env[m[1]] = m[2];
    }
    const e = env.CMUX_DOGFOOD_STACK_EMAIL ?? env.CMUX_UITEST_STACK_EMAIL;
    const p = env.CMUX_DOGFOOD_STACK_PASSWORD ?? env.CMUX_UITEST_STACK_PASSWORD;
    if (e && p) return { email: e, password: p };
  }
  return null;
}

async function signIn(): Promise<StackTokens> {
  if (stackTokens) return stackTokens;
  if (!API_URL) throw new Error("CMUX_DASHBOARD_API_URL is not set");
  const creds = loadDevSecrets();
  if (!creds) throw new Error("no dogfood Stack credentials (run scripts/setup-team-dev.sh)");
  const config = await (await fetch(`${API_URL}/api/cli/config`)).json();
  const auth = config.auth ?? {};
  const res = await fetch(`${auth.apiUrl}/api/v1/auth/password/sign-in`, {
    method: "POST",
    headers: {
      "x-stack-access-type": "client",
      "x-stack-project-id": auth.projectId,
      "x-stack-publishable-client-key": auth.publishableClientKey,
      "content-type": "application/json",
    },
    body: JSON.stringify({ email: creds.email, password: creds.password }),
  });
  if (!res.ok) throw new Error(`Stack sign-in failed: HTTP ${res.status}`);
  const body = await res.json();
  stackTokens = { access: body.access_token, refresh: body.refresh_token };
  return stackTokens;
}

async function api(path: string, init: RequestInit = {}): Promise<any> {
  const tokens = await signIn();
  const res = await fetch(`${API_URL}${path}`, {
    ...init,
    headers: {
      ...(init.headers ?? {}),
      authorization: `Bearer ${tokens.access}`,
      "x-stack-refresh-token": tokens.refresh,
      "content-type": "application/json",
    },
  });
  if (res.status === 401) stackTokens = null;
  if (!res.ok) throw new Error(`${init.method ?? "GET"} ${path}: HTTP ${res.status} ${await res.text()}`);
  return res.json();
}

const cloudMachines = new Map<string, Machine>();

async function listCloudMachines(): Promise<Machine[]> {
  if (!API_URL) return [];
  try {
    const body = await api("/api/vm");
    cloudWarning = null;
    const out: Machine[] = [];
    for (const vm of body.vms ?? []) {
      const existing = cloudMachines.get(vm.id);
      const machine: Machine = existing ?? {
        id: `cloud:${vm.id}`,
        name: vm.displayName ?? `${vm.provider} ${vm.id.slice(0, 8)}`,
        source: "cloud",
        routes: [],
        status: "unknown",
        relays: [],
        stateDir: join(STATE, "cloud", vm.id),
      };
      machine.status = vm.status === "running" ? "online" : vm.status === "paused" ? "offline" : "unknown";
      machine.name = `${vm.displayName ?? vm.provider + " " + vm.id.slice(0, 8)} · ${vm.status}`;
      cloudMachines.set(vm.id, machine);
      out.push(machine);
    }
    return out;
  } catch (error) {
    cloudWarning = String((error as Error).message);
    return [...cloudMachines.values()];
  }
}

function writeSecretFile(path: string, content: string) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, content + "\n", { mode: 0o600 });
  chmodSync(path, 0o600);
}

/** Attach to a cloud VM: mint relay grants (and an invitation on first use), same as the Mac app. */
async function attachCloud(machine: Machine): Promise<void> {
  const vmId = machine.id.slice("cloud:".length);
  const body = await api(`/api/vm/${vmId}/attach-endpoint`, {
    method: "POST",
    body: JSON.stringify({ transport: "cmux-remote", deviceFingerprint: dashboardFingerprint() }),
  });
  if (body.transport !== "cmux-remote") throw new Error(`VM ${vmId} did not return a cmux-remote endpoint`);
  const relays: any[] = body.relays ?? [];
  if (relays.length < 2) throw new Error(`VM ${vmId} is not native-relay provisioned (relays=${relays.length}); create a new VM with CMUX_NATIVE_RELAY_ENABLED=1`);
  machine.relays = relays.map((g, i) => {
    const ticketFile = join(machine.stateDir, `ticket-${i}`);
    writeSecretFile(ticketFile, g.ticket);
    return { route: g.route, slot: g.slot, ticketFile };
  });
  machine.routes = machine.relays.map((r) => r.route);
  if (body.invitation?.uri) {
    machine.inviteFile = join(machine.stateDir, "invite.txt");
    writeSecretFile(machine.inviteFile, body.invitation.uri);
    const invitationId = body.invitation.invitationId;
    machine.approve = async () => {
      for (let i = 0; i < 60; i++) {
        const r = await api(`/api/vm/${vmId}/cmux-remote/approve`, { method: "POST", body: JSON.stringify({ invitationId }) });
        if (r.state !== "pending") return;
        await Bun.sleep(1000);
      }
    };
  } else {
    machine.inviteFile = undefined;
    machine.approve = undefined;
  }
  machine.refreshTickets = async () => {
    const r = await api(`/api/vm/${vmId}/relay-ticket`, { method: "POST", body: "{}" });
    (r.relays ?? []).forEach((g: any, i: number) => {
      const cred = machine.relays.find((c) => c.route === g.route) ?? machine.relays[i];
      if (cred?.ticketFile) writeSecretFile(cred.ticketFile, g.ticket);
    });
  };
}

function dashboardFingerprint(): string {
  const file = join(STATE, "fingerprint");
  if (!existsSync(file)) writeSecretFile(file, randomUUID().replace(/-/g, ""));
  return readFileSync(file, "utf8").trim();
}

async function allMachines(): Promise<Machine[]> {
  const lab = labMachine();
  return [...(lab ? [lab] : []), ...(await listCloudMachines())];
}

// ---------- relay client bridge ------------------------------------------------------
// One headless `cmux-tui remote connect` per machine gives a local mux socket.
// PTY sessions are opened through that socket (see ptyBridge below).

type Link = { proc: ChildProcess; socket: string | null; snapshot: any; waiters: ((s: string) => void)[]; listeners: Set<(snap: any) => void> };
const links = new Map<string, Link>();

function relayArgs(machine: Machine): string[] {
  const args: string[] = [];
  for (const r of machine.relays) {
    args.push("--relay-route", r.route, "--relay-slot", r.slot);
    if (r.ticketFile) args.push("--relay-ticket-file", r.ticketFile);
    else if (r.ticketCommand) {
      args.push("--relay-ticket-command", r.ticketCommand[0]);
      for (const a of r.ticketCommand.slice(1)) args.push("--relay-ticket-command-arg", a);
    }
  }
  return args;
}

async function ensureLink(machine: Machine): Promise<Link> {
  const existing = links.get(machine.id);
  if (existing && existing.proc.exitCode === null) return existing;
  if (machine.source === "cloud") await attachCloud(machine);
  if (!machine.relays.length) throw new Error(`${machine.name}: no relay credentials`);
  const socket = join(STATE, `link-${machine.id.replace(/[^A-Za-z0-9]/g, "_").slice(0, 32)}-${process.pid}.sock`);
  const args = ["remote", "connect", machine.relays[0].route, ...relayArgs(machine),
    "--state-dir", machine.stateDir, "--local-socket", socket, "--headless", "--json",
    "--device-name", `relay-dashboard-${hostname()}`];
  if (machine.inviteFile) args.push("--invite-file", machine.inviteFile);
  const proc = spawn(TUI, args, { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, HOME: process.env.HOME } });
  const link: Link = { proc, socket: null, snapshot: null, waiters: [], listeners: new Set() };
  links.set(machine.id, link);
  createInterface({ input: proc.stdout! }).on("line", (line) => {
    try {
      const msg = JSON.parse(line);
      if (msg.event === "connection-snapshot") {
        link.snapshot = msg.connection;
        if (msg.local_socket && !link.socket) {
          link.socket = msg.local_socket;
          for (const w of link.waiters) w(msg.local_socket);
          link.waiters = [];
        }
        for (const l of link.listeners) l(msg.connection);
      }
    } catch { /* not JSON */ }
  });
  let stderr = "";
  proc.stderr!.on("data", (d) => { stderr += d.toString(); if (stderr.length > 8000) stderr = stderr.slice(-8000); });
  proc.on("exit", (code) => {
    console.log(`[link ${machine.id}] exited ${code}: ${stderr.trim().split("\n").slice(-3).join(" | ")}`);
    links.delete(machine.id);
    for (const l of link.listeners) l({ state: "closed", generation: link.snapshot?.generation ?? 0, transport: { route: "" }, physical_link_count: 0, stderr });
  });
  if (machine.approve) machine.approve().catch((e) => console.log(`[link ${machine.id}] approve failed: ${e.message}`));
  await new Promise<void>((resolveSocket, reject) => {
    const timer = setTimeout(() => reject(new Error(`${machine.name}: no connection snapshot within 90s\n${stderr}`)), 90_000);
    link.waiters.push(() => { clearTimeout(timer); resolveSocket(); });
    proc.on("exit", () => { clearTimeout(timer); reject(new Error(`${machine.name}: client exited\n${stderr}`)); });
  });
  return link;
}

// ---------- PTY bridge -----------------------------------------------------------
// Filled in by ptyBridge(): opens a PTY on the remote daemon through the link's
// local socket and pipes bytes to/from the browser WebSocket.
import { openPty, type PtyHandle } from "./pty";

// ---------- HTTP + WebSocket --------------------------------------------------------

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8", ".js": "application/javascript", ".wasm": "application/wasm",
  ".json": "application/json", ".gz": "application/octet-stream", ".bin": "application/octet-stream", ".txt": "text/plain",
};

function serve(path: string): Response {
  if (!existsSync(path)) return new Response("Not Found", { status: 404 });
  const ext = path.slice(path.lastIndexOf("."));
  return new Response(Bun.file(path), { headers: { "content-type": MIME[ext] ?? "application/octet-stream" } });
}

function underneath(base: string, rel: string): string | null {
  const full = resolve(base, rel);
  return full.startsWith(resolve(base) + "/") ? full : null;
}

type WsData = { machineId: string; cols: number; rows: number; pty: PtyHandle | null; unsubscribe: (() => void) | null; queued: (string | Uint8Array)[] };

function handleMessage(ws: { data: WsData }, message: string | Uint8Array | Buffer) {
  const pty = ws.data.pty;
  // Output (the vt-state replay) can reach the browser before openPty()
  // returns; keep early keystrokes instead of dropping them.
  if (!pty) { ws.data.queued.push(typeof message === "string" ? message : new Uint8Array(message)); return; }
  if (typeof message === "string") {
    if (message.startsWith("{")) {
      try {
        const msg = JSON.parse(message);
        if (msg.type === "resize") { pty.resize(msg.cols, msg.rows); return; }
      } catch { /* literal text */ }
    }
    pty.write(Buffer.from(message, "utf8"));
  } else {
    pty.write(Buffer.from(message));
  }
}

const server = Bun.serve<WsData>({
  hostname: "127.0.0.1",
  port: PORT,
  async fetch(req, srv) {
    const url = new URL(req.url);
    const p = url.pathname;
    if (p === "/" || p === "/index.html") return serve(join(here, "index.html"));
    if (p.startsWith("/dist/")) { const f = underneath(join(GHOSTTY_WEB, "dist"), p.slice(6)); return f ? serve(f) : new Response("Forbidden", { status: 403 }); }
    if (p === "/ghostty-vt.wasm") return serve(WASM);
    if (p.startsWith("/atlas/")) { const f = underneath(join(GHOSTTY_WEB, "atlas"), p.slice(7)); return f ? serve(f) : new Response("Forbidden", { status: 403 }); }
    if (p === "/api/machines") {
      const machines = await allMachines();
      return Response.json({
        shards: await labShards(),
        machines: machines.map((m) => ({ id: m.id, name: m.name, source: m.source, routes: m.routes, status: m.status, linked: links.has(m.id) })),
        cloud: API_URL ? { apiUrl: API_URL, warning: cloudWarning } : null,
      });
    }
    const shardCmd = /^\/api\/shards\/([ab])\/(drain|start)$/.exec(p);
    if (shardCmd && req.method === "POST") {
      const proc = Bun.spawn([LAB_SCRIPT, shardCmd[2], shardCmd[1]], { env: { ...process.env, CMUX_RELAY_LAB_DIR: LAB }, stdout: "pipe", stderr: "pipe" });
      const out = await new Response(proc.stdout).text();
      const err = await new Response(proc.stderr).text();
      return Response.json({ ok: (await proc.exited) === 0, out, err });
    }
    if (p === "/ws") {
      const machineId = url.searchParams.get("machine") ?? "";
      const cols = Number(url.searchParams.get("cols") ?? 80);
      const rows = Number(url.searchParams.get("rows") ?? 24);
      if (srv.upgrade(req, { data: { machineId, cols, rows, pty: null, unsubscribe: null, queued: [] } })) return undefined as any;
      return new Response("upgrade failed", { status: 400 });
    }
    return new Response("Not Found", { status: 404 });
  },
  websocket: {
    async open(ws) {
      const send = (obj: object) => { try { ws.send(JSON.stringify(obj)); } catch { /* closed */ } };
      try {
        const machine = (await allMachines()).find((m) => m.id === ws.data.machineId);
        if (!machine) { ws.close(4004, "unknown machine"); return; }
        send({ type: "notice", text: `opening relay link (${machine.routes.join(", ")})` });
        const link = await ensureLink(machine);
        const publish = (c: any) => send({ type: "snapshot", state: c.state, generation: c.generation, route: c.transport?.route ?? "", links: c.physical_link_count ?? 0 });
        if (link.snapshot) publish(link.snapshot);
        link.listeners.add(publish);
        ws.data.unsubscribe = () => link.listeners.delete(publish);
        send({ type: "notice", text: `link up via ${link.snapshot?.transport?.route ?? "relay"}; opening PTY` });
        ws.data.pty = await openPty({
          tui: TUI,
          socket: link.socket!,
          cols: ws.data.cols,
          rows: ws.data.rows,
          onOutput: (bytes) => { try { ws.sendBinary(bytes); } catch { /* closed */ } },
          onExit: (why) => { send({ type: "notice", text: `pty closed: ${why}` }); try { ws.close(1000, "pty exited"); } catch { /* closed */ } },
        });
        for (const early of ws.data.queued.splice(0)) handleMessage(ws, early);
      } catch (error) {
        send({ type: "notice", text: `error: ${(error as Error).message}` });
        ws.close(4000, String((error as Error).message).slice(0, 120));
      }
    },
    message(ws, message) { handleMessage(ws, message); },
    close(ws) {
      ws.data.unsubscribe?.();
      ws.data.pty?.close();
    },
  },
});

function shutdown() {
  for (const link of links.values()) link.proc.kill("SIGTERM");
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.on("exit", () => { for (const link of links.values()) link.proc.kill("SIGTERM"); });

console.log(`cmux relay dashboard: http://127.0.0.1:${server.port}`);
console.log(`  cmux-tui: ${TUI}`);
console.log(`  ghostty-web: ${GHOSTTY_WEB}`);
console.log(`  relay lab: ${LAB}${readLabEnv() ? "" : " (not running; scripts/relay-lab.sh up)"}`);
console.log(`  cloud API: ${API_URL ?? "(unset; export CMUX_DASHBOARD_API_URL to list Cloud VMs)"}`);
