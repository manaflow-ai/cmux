#!/usr/bin/env node
// tui-cloud-provider — a cmux-tui machine-provider-v1 implementation backed by
// Freestyle beta VMs. The TUI appends `control` or `stream` to this argv.
//
//   tui-cloud-provider control   JSON-lines control channel on stdio
//   tui-cloud-provider stream    one machine transport on stdio
//
// The rail sees every Freestyle VM tagged product=tui-cloud; create_machine
// boots a fresh one from the base snapshot. A machine transport is a byte pipe
// into a persistent local `cmux-tui remote connect --headless` bridge socket,
// which carries protocol-v12 to the VM daemon over iroh.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { connect as netConnect } from "node:net";
import {
  mkdirSync, writeFileSync, readFileSync, existsSync, unlinkSync,
  readdirSync, openSync, constants,
} from "node:fs";
import { randomBytes } from "node:crypto";
import { client, waitRunning, sh, sleep, createWithRetry } from "./client.mjs";

const PROTOCOL = "cmux.machine-provider";
const VERSION = 1;
const SESSION = process.env.TUI_CLOUD_SESSION ?? "main";
const CMUX_ENV = { HOME: "/root" };
const LOCAL_BIN = new URL("../node_modules/cmux-tui-darwin-arm64/bin/cmux-tui", import.meta.url).pathname;

const STATE_DIR = process.env.TUI_CLOUD_STATE ?? `${process.env.HOME}/.cache/tui-cloud`;
const BRIDGES = `${STATE_DIR}/bridges`;
const TICKETS = `${STATE_DIR}/tickets`;
const MUTATIONS = `${STATE_DIR}/mutations`;
for (const d of [STATE_DIR, BRIDGES, TICKETS, MUTATIONS]) mkdirSync(d, { recursive: true, mode: 0o700 });

const log = (...a) => process.stderr.write(`[tui-cloud-provider] ${a.join(" ")}\n`);

// ---------------------------------------------------------------- state helpers
const revFile = `${STATE_DIR}/revision`;
function getRevision() {
  try { return parseInt(readFileSync(revFile, "utf8"), 10) || 1; } catch { return 1; }
}
function bumpRevision() {
  const next = getRevision() + 1;
  writeFileSync(revFile, String(next), { mode: 0o600 });
  return next;
}

const genFile = `${STATE_DIR}/generation.json`;
function saveGeneration(token) { writeFileSync(genFile, JSON.stringify({ token }), { mode: 0o600 }); }
function generationToken() {
  try { return JSON.parse(readFileSync(genFile, "utf8")).token; } catch { return null; }
}

// ---------------------------------------------------------------- protocol helpers
function respond(id, result) {
  process.stdout.write(JSON.stringify({ protocol: PROTOCOL, version: VERSION, id, result }) + "\n");
}
function respondError(id, code, message, retryable = false) {
  process.stdout.write(JSON.stringify({ protocol: PROTOCOL, version: VERSION, id, error: { code, message, retryable } }) + "\n");
}
function event(name, params) {
  process.stdout.write(JSON.stringify({ protocol: PROTOCOL, version: VERSION, event: name, params }) + "\n");
}

// ---------------------------------------------------------------- catalog
async function listMachines() {
  const freestyle = client();
  const { vms } = await freestyle.vms.list({ metadata: "product:tui-cloud", limit: 100 });
  return vms.filter((v) => v.metadata?.role === "instance");
}

function toDescriptor(v) {
  const status = { starting: "connecting", pausing: "connecting", running: "running", paused: "sleeping", stopped: "stopped" }[v.state] ?? "unavailable";
  return {
    id: v.id,
    display_name: v.displayName ?? v.slug ?? v.id,
    subtitle: `freestyle ${v.state}`,
    status,
    connectable: v.state === "running",
    workspace_create: { owner: "session" },
  };
}

async function snapshotResult() {
  const machines = (await listMachines()).map(toDescriptor);
  return {
    revision: getRevision(),
    scopes: [{ id: "personal", display_name: "Personal", kind: "personal", can_admin: true }],
    selected_scope_id: "personal",
    machines,
    capabilities: { create_machine: true, connect_external_machine: false },
    actions: [],
  };
}

// ---------------------------------------------------------------- bridges
function bridgePaths(vmId) {
  return {
    sock: `${BRIDGES}/${vmId}.sock`,
    pid: `${BRIDGES}/${vmId}.pid`,
    meta: `${BRIDGES}/${vmId}.json`,
    log: `${BRIDGES}/${vmId}.log`,
  };
}

function bridgeAlive(vmId) {
  const { sock, pid } = bridgePaths(vmId);
  if (!existsSync(sock) || !existsSync(pid)) return false;
  try {
    process.kill(parseInt(readFileSync(pid, "utf8"), 10), 0);
    return true;
  } catch { return false; }
}

async function ensureDaemon(vm) {
  const probe = await vm.exec({ command: `cmux server status --session ${SESSION} >/dev/null 2>&1; echo $?`, env: CMUX_ENV });
  if ((probe.stdout ?? "").trim() !== "0") {
    await sh(vm, `setsid nohup cmux server start --session ${SESSION} --iroh >/var/log/cmux-tui.log 2>&1 </dev/null & sleep 5; cmux server status --session ${SESSION} >/dev/null`, { timeoutMs: 120_000, env: CMUX_ENV });
  }
}

async function autoApprove(vm, { timeoutMs = 120_000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const pending = await sh(vm, `cmux remote enroll pending --session ${SESSION} --json 2>/dev/null || echo '[]'`, { timeoutMs: 30_000, env: CMUX_ENV });
      const ids = [...pending.matchAll(/"invitation_id"\s*:\s*"([^"]+)"/g)].map((m) => m[1]);
      for (const pid of ids) {
        await sh(vm, `cmux remote enroll approve ${pid} --session ${SESSION} 2>&1`, { timeoutMs: 30_000, env: CMUX_ENV });
        log(`approved invitation ${pid}`);
        return true;
      }
    } catch (e) { log(`approve poll: ${e.message}`); }
    await sleep(2000);
  }
  return false;
}

function spawnBridge(vmId, connectArgs) {
  const { sock, pid, log: logPath } = bridgePaths(vmId);
  try { unlinkSync(sock); } catch {}
  const fd = openSync(logPath, "a");
  const child = spawn(LOCAL_BIN, connectArgs, { stdio: ["ignore", fd, fd], detached: true });
  child.unref();
  writeFileSync(pid, String(child.pid), { mode: 0o600 });
  log(`bridge for ${vmId} pid ${child.pid}`);
}

async function waitBridgeConnected(vmId, { timeoutMs = 120_000 } = {}) {
  const { sock, log: logPath } = bridgePaths(vmId);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const content = readFileSync(logPath, "utf8");
      if (content.includes('"state":"connected"') && existsSync(sock)) return true;
      if (content.includes('"state":"error"') || content.includes("failed")) return false;
    } catch {}
    await sleep(1000);
  }
  return false;
}

// Bring up a persistent local mux socket bridged to the VM daemon.
// First contact uses an invite + auto-approve; later contacts reuse the
// enrolled device via --daemon.
async function ensureBridge(vmId) {
  if (bridgeAlive(vmId)) return bridgePaths(vmId).sock;

  const freestyle = client();
  const vm = freestyle.vms.ref(vmId);
  const d = await vm.data();
  if (d.state === "paused" || d.state === "stopped") await vm.start();
  await waitRunning(vm);
  await ensureDaemon(vm);

  const { meta } = bridgePaths(vmId);
  let fingerprint = null;
  try { fingerprint = JSON.parse(readFileSync(meta, "utf8")).fingerprint; } catch {}

  if (fingerprint) {
    spawnBridge(vmId, ["remote", "connect", "--daemon", fingerprint, "--headless", "--json", "--local-socket", bridgePaths(vmId).sock]);
    if (await waitBridgeConnected(vmId)) return bridgePaths(vmId).sock;
    log(`daemon reconnect failed for ${vmId}, falling back to invite`);
  }

  // Invite flow: mint on the daemon, connect locally, approve on the daemon.
  const out = await sh(vm, `cmux remote enroll create --session ${SESSION} 2>&1`, { timeoutMs: 60_000, env: CMUX_ENV });
  const invite = out.match(/cmux:\/\/enroll\/\S+/)?.[0];
  if (!invite) throw new Error(`no invite in enroll output: ${out}`);
  const inviteFile = `${BRIDGES}/${vmId}.invite`;
  writeFileSync(inviteFile, invite + "\n", { mode: 0o600 });

  spawnBridge(vmId, ["remote", "connect", "--invite-file", inviteFile, "--device-name", "tui-cloud-provider", "--headless", "--json", "--local-socket", bridgePaths(vmId).sock]);
  const approved = await autoApprove(vm);
  if (!approved) throw new Error("no pending invitation appeared for approval");
  if (!(await waitBridgeConnected(vmId))) throw new Error(`bridge did not connect; see ${bridgePaths(vmId).log}`);

  // Persist the daemon fingerprint for invite-free reconnects.
  try {
    const payload = JSON.parse(Buffer.from(invite.replace("cmux://enroll/", ""), "base64").toString("utf8"));
    if (payload.daemon_fingerprint) {
      writeFileSync(meta, JSON.stringify({ fingerprint: payload.daemon_fingerprint }), { mode: 0o600 });
    }
  } catch (e) { log(`fingerprint parse: ${e.message}`); }
  try { unlinkSync(inviteFile); } catch {}
  return bridgePaths(vmId).sock;
}

function killBridge(vmId) {
  const { pid, sock, meta } = bridgePaths(vmId);
  try { process.kill(parseInt(readFileSync(pid, "utf8"), 10)); } catch {}
  for (const f of [pid, sock, meta]) { try { unlinkSync(f); } catch {} }
}

// ---------------------------------------------------------------- control channel
async function runControl() {
  let generationBearer = null;
  const freestyle = client();

  // Push snapshot_changed when the Freestyle catalog drifts.
  let lastHash = "";
  const poll = setInterval(async () => {
    try {
      const vms = await listMachines();
      const hash = vms.map((v) => `${v.id}:${v.state}`).sort().join(",");
      // reap bridges for deleted VMs
      for (const f of readdirSync(BRIDGES)) {
        if (!f.endsWith(".sock")) continue;
        const vmId = f.slice(0, -5);
        if (!vms.some((v) => v.id === vmId)) killBridge(vmId);
      }
      if (hash !== lastHash) {
        lastHash = hash;
        event("snapshot_changed", { revision: bumpRevision() });
      }
    } catch (e) { log(`poll: ${e.message}`); }
  }, 10_000);
  poll.unref();

  const rl = createInterface({ input: process.stdin, terminal: false });
  for await (const line of rl) {
    if (!line.trim()) continue;
    let req;
    try { req = JSON.parse(line); } catch { continue; }
    const { id, method, params = {} } = req;
    try { writeFileSync(`${STATE_DIR}/control-requests.log`, JSON.stringify({ t: Date.now(), method, id, params }) + "\n", { flag: "a" }); } catch {}

    // hello must be the first request.
    if (!generationBearer && method !== "hello") {
      respondError(id ?? "?", "permission_denied", "first request must be hello");
      continue;
    }

    try {
      switch (method) {
        case "hello": {
          if (generationBearer) { respondError(id, "permission_denied", "second hello"); break; }
          generationBearer = params.token;
          saveGeneration(generationBearer);
          process.stdout.write(JSON.stringify({
            protocol: PROTOCOL, version: VERSION, id,
            capabilities: [],
            result: { provider_id: "tui-cloud", provider_name: "tui-cloud (Freestyle)", negotiated_version: VERSION },
          }) + "\n");
          break;
        }
        case "snapshot": {
          respond(id, await snapshotResult());
          break;
        }
        case "create_machine": {
          // Durable idempotency on mutation_id.
          const mutFile = `${MUTATIONS}/${params.mutation_id}`;
          if (existsSync(mutFile)) {
            respond(id, JSON.parse(readFileSync(mutFile, "utf8")));
            break;
          }
          const slug = `tc-${randomBytes(3).toString("hex")}`;
          const snapList = await freestyle.vms.snapshots.list({ limit: 100 });
          const base = snapList.snapshots
            .filter((s) => (s.slug ?? "").startsWith("tui-cloud-base-"))
            .sort((a, b) => b.createdAt.localeCompare(a.createdAt))[0];
          if (!base) { respondError(id, "unavailable", "no tui-cloud-base snapshot; run tui-cloud build-snapshot", true); break; }
          const { vmId } = await createWithRetry(freestyle, {
            snapshotId: base.id,
            slug,
            displayName: `tui-cloud ${slug}`,
            metadata: { product: "tui-cloud", role: "instance" },
            ipMode: "dualStack",
            firewall: { rules: [
              { action: "allow", source: {}, destination: { public: true } },
              { action: "allow", source: { public: true }, destination: { port: 22, protocol: "tcp" } },
            ] },
          });
          const result = { machine_id: vmId, revision: bumpRevision() };
          writeFileSync(mutFile, JSON.stringify(result), { mode: 0o600 });
          respond(id, result);
          event("snapshot_changed", { revision: result.revision });
          // Warm the daemon in the background so open_machine is fast.
          (async () => {
            try {
              const vm = freestyle.vms.ref(vmId);
              await waitRunning(vm);
              await ensureDaemon(vm);
              bumpRevision();
              event("snapshot_changed", { revision: getRevision() });
            } catch (e) { log(`warm ${vmId}: ${e.message}`); }
          })();
          break;
        }
        case "open_machine": {
          const vmId = params.machine_id;
          await ensureBridge(vmId); // throws on failure -> error response
          const ticket = randomBytes(32).toString("base64url");
          const connectionId = randomBytes(16).toString("hex");
          const expiresAt = new Date(Date.now() + 60_000).toISOString();
          writeFileSync(`${TICKETS}/${ticket}`, JSON.stringify({ vmId, connectionId, expiresAt }), { mode: 0o600 });
          respond(id, {
            connection_id: connectionId,
            transport: { kind: "provider_stream", ticket, expires_at: expiresAt },
          });
          break;
        }
        case "close_machine": {
          respond(id, { revision: bumpRevision() });
          break;
        }
        default:
          respondError(id, "invalid_input", `unsupported method ${method}`);
      }
    } catch (e) {
      respondError(id, "internal", e?.message ?? String(e), true);
    }
  }
  clearInterval(poll);
}

// ---------------------------------------------------------------- stream transport
async function runStream() {
  const rl = createInterface({ input: process.stdin, terminal: false });
  const firstLine = await Promise.race([
    (async () => { for await (const line of rl) return line; })(),
    sleep(10_000).then(() => null),
  ]);
  if (!firstLine) process.exit(1);

  let hs;
  try { hs = JSON.parse(firstLine); } catch { process.exit(1); }
  const accept = () => process.stdout.write(JSON.stringify({ accepted: true }) + "\n");
  const reject = () => { process.stdout.write(JSON.stringify({ accepted: false }) + "\n"); process.exit(1); };

  if (hs.protocol !== PROTOCOL || hs.version !== VERSION || hs.role !== "transport") reject();
  if (!generationToken() || hs.token !== generationToken()) reject();

  const ticketFile = `${TICKETS}/${hs.ticket}`;
  let ticketData = null;
  try { ticketData = JSON.parse(readFileSync(ticketFile, "utf8")); } catch { reject(); }
  unlinkSync(ticketFile); // single use
  if (new Date(ticketData.expiresAt).getTime() < Date.now()) reject();
  if (!bridgeAlive(ticketData.vmId)) reject();

  accept();
  rl.close();

  // Byte-pipe stdio <-> the VM's bridge socket (protocol-v12 JSON lines both ways).
  const sock = netConnect(bridgePaths(ticketData.vmId).sock);
  sock.on("error", (e) => { log(`bridge socket: ${e.message}`); process.exit(1); });
  process.stdin.pipe(sock, { end: true });
  sock.pipe(process.stdout, { end: true });
  sock.on("close", () => process.exit(0));
  process.stdin.on("end", () => sock.end());
}

// ---------------------------------------------------------------- entry
const sub = process.argv[2];
if (sub === "control") runControl().catch((e) => { log(e?.stack ?? e); process.exit(1); });
else if (sub === "stream") runStream().catch((e) => { log(e?.stack ?? e); process.exit(1); });
else {
  console.error("usage: tui-cloud-provider control|stream   (invoked by cmux --machine-provider-command)");
  process.exit(2);
}
