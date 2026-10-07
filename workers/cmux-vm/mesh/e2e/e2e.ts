// cmux mesh M1c end-to-end proof (cx-0op.3, M1-PLAN.md). Run on cmux-lawrence-2 by run-m1.sh.
//
// The provider API key arrives on stdin (one line, a bare key or FREESTYLE_API_KEY=...),
// is held in memory only and is never printed. The real cmux VM API handlers
// (makeWebHandler) run in this process with in-memory stores, so no database is
// touched and no migration is applied. Every provider resource the handlers
// create is written to a ledger at creation; mutating calls on any provider id
// not in the ledger are refused; at most 20 live resources. Cleanup deletes by
// exact cmux id through the API, then GETs every ledger id from the provider
// by exact id and expects 404.
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { Effect, Layer, Option, Redacted } from "effect";
import { makeWebHandler } from "../../src/app.ts";
import { generateApiKey, hashApiKey, SessionVerifier, TeamMembership } from "../../src/auth/credentials.ts";
import { TeamAdmin } from "../../src/auth/team-admin.ts";
import { ApiKeyAdminStore } from "../../src/db/api-keys.ts";
import { makeMemoryMeshStore } from "../../src/db/mesh-memory.ts";
import { SnapshotStore } from "../../src/db/snapshots.ts";
import { ApiKeyStore, AuditStore, OwnershipStore, type OwnedResource } from "../../src/db/stores.ts";
import { SCOPES } from "../../src/domain/scopes.ts";
import { newApiKeyId, TenantId } from "../../src/lib/ids.ts";
import { memoryLimitsLayer } from "../../src/limits/service.ts";
import { meshConfigLayer } from "../../src/mesh/config.ts";
import { tenantPolicyLayer } from "../../src/policy.ts";
import { Entitlements } from "../../src/proofs/tenant-may-create.ts";
import { UpstreamClient } from "../../src/upstream/client.ts";
import { makeUpstreamClient } from "../../src/upstream/live.ts";
import { makeUpstreamMesh } from "../../src/upstream/live-mesh.ts";
import { makeUpstreamSnapshots } from "../../src/upstream/live-snapshots.ts";
import { makeUpstreamTerminals } from "../../src/upstream/live-terminals.ts";
import { UpstreamMesh } from "../../src/upstream/mesh.ts";
import { UpstreamSnapshots } from "../../src/upstream/snapshots.ts";
import { UpstreamTerminals } from "../../src/upstream/terminals.ts";

const AGENT = process.argv[2] ?? "";
const UPSTREAM = "https://api.freestyle.sh";
const RUN = `m1c${Date.now().toString(36)}`;
const TENANT = `team_mesh_m1_${RUN}`;
const OUT = join(import.meta.dir, "out", RUN);
mkdirSync(OUT, { recursive: true });
const LEDGER = join(OUT, "ledger.jsonl");
const RESULTS = join(OUT, "results.jsonl");
const MAX_LIVE = 20;

const raw = (await new Response(Bun.stdin.stream()).text()).trim();
const PROVIDER_KEY = (/^FREESTYLE_API_KEY=(.*)$/mu.exec(raw)?.[1] ?? raw).trim().replace(/^["']|["']$/gu, "");
if (PROVIDER_KEY.length < 10) throw new Error("no provider key on stdin");

const log = (event: string, data: Record<string, unknown> = {}) => {
  const line = JSON.stringify({ t: Date.now(), event, ...data });
  appendFileSync(RESULTS, line + "\n");
  console.log(line);
};

// ---- provider fetch guard and ledger ----
type Kind = "vm" | "vpc" | "tunnel" | "rule";
const KINDS: Record<string, Kind> = { vms: "vm", vpcs: "vpc", tunnels: "tunnel", "firewall/rules": "rule" };
const PATHS: Record<Kind, string> = { vm: "vms", vpc: "vpcs", tunnel: "tunnels", rule: "firewall/rules" };
const ledger = new Map<string, Kind>();
const live = new Set<string>();
const record = (op: string, kind: Kind, id: string, note = "") => appendFileSync(LEDGER, JSON.stringify({ t: new Date().toISOString(), run: RUN, op, kind, id, note }) + "\n");

const guardedFetch = async (request: Request): Promise<Response> => {
  const url = new URL(request.url);
  if (url.origin !== UPSTREAM) return fetch(request);
  const match = /^\/v5\/(vms|vpcs|tunnels|firewall\/rules)(?:\/([^/]+))?(\/.*)?$/u.exec(url.pathname);
  if (match === null) throw new Error(`guard: unexpected provider path ${request.method} ${url.pathname}`);
  const kind = KINDS[match[1] ?? ""];
  const id = match[2] === undefined ? null : decodeURIComponent(match[2]);
  if (kind === undefined) throw new Error("guard: unknown kind");
  if (request.method !== "GET" && id !== null && !ledger.has(id)) throw new Error(`guard: refusing ${request.method} on an id this run did not create`);
  if (request.method === "POST" && id === null && live.size >= MAX_LIVE) throw new Error("guard: 20 live resources");
  const sent = request.method === "GET" ? null : await request.clone().text();
  const response = await fetch(request);
  if (!response.ok && !(request.method === "GET" && response.status === 404)) {
    log("provider-error", { method: request.method, path: url.pathname.replace(/[^/]{20,}/gu, "<id>"), status: response.status, body: (await response.clone().text()).slice(0, 300), sent: sent?.slice(0, 300) });
  }
  if (request.method === "POST" && id === null && response.ok) {
    const body: Record<string, unknown> = await response.clone().json();
    const created = String(body["tunnelId"] ?? body["id"] ?? body["vmId"] ?? "");
    if (created === "") throw new Error("guard: create without an id");
    ledger.set(created, kind);
    live.add(created);
    record("create", kind, created);
  }
  if (request.method === "DELETE" && id !== null && (response.ok || response.status === 404)) {
    live.delete(id);
    record("delete", kind, id, String(response.status));
    // Rules naming a deleted tunnel or VM go with it upstream.
    if (kind === "tunnel" || kind === "vm") for (const [rid, k] of ledger) if (k === "rule" && live.delete(rid)) record("gone", "rule", rid, `with ${kind}`);
  }
  return response;
};

// ---- the cmux VM API, in process ----
const tenantId = TenantId.make(TENANT);
const apiKey = generateApiKey();
const apiKeyHash = await Effect.runPromise(hashApiKey(apiKey));
const resources: OwnedResource[] = [];
const deleted = new Set<string>();
const audit: unknown[] = [];
const upstreamConfig = { baseUrl: UPSTREAM, apiKey: Redacted.make(PROVIDER_KEY), fetch: guardedFetch };
const unused = () => Effect.die("not used by the M1c proof");
const services = Layer.mergeAll(
  Layer.succeed(OwnershipStore, {
    find: (t, kind, id) => Effect.sync(() => Option.fromNullable(resources.find((r) => r.tenantId === t && r.kind === kind && r.cmuxId === id && !deleted.has(id)))),
    record: (resource) => Effect.sync(() => void resources.push(resource)),
    listPage: (t, kind, page) =>
      Effect.sync(() => resources.filter((r) => r.tenantId === t && r.kind === kind && !deleted.has(r.cmuxId)).slice(0, page.limit)),
    countLive: (t, kind) => Effect.sync(() => resources.filter((r) => r.tenantId === t && r.kind === kind && !deleted.has(r.cmuxId)).length),
    markDeleted: (_t, _kind, id) => Effect.sync(() => void deleted.add(id)),
  }),
  Layer.succeed(AuditStore, { append: (entry) => Effect.sync(() => void audit.push({ ...entry, at: entry.at.toISOString() })) }),
  Layer.succeed(ApiKeyStore, {
    findActiveByHash: (hash) =>
      Effect.succeed(
        hash === apiKeyHash ? Option.some({ id: newApiKeyId(), tenantId, scopes: SCOPES.filter((s) => s !== "admin"), resourceAllowlist: null, expiresAt: null }) : Option.none(),
      ),
  }),
  tenantPolicyLayer({ environment: "local" }),
  Layer.succeed(Entitlements, { mayCreate: (t) => Effect.succeed(t === tenantId) }),
  memoryLimitsLayer(),
  Layer.succeed(UpstreamClient, makeUpstreamClient(upstreamConfig)),
  Layer.succeed(SessionVerifier, { verify: () => Effect.die("sessions are not used by the M1c proof") }),
  Layer.succeed(TeamMembership, { isMember: () => Effect.succeed(false) }),
  Layer.succeed(TeamAdmin, { isAdmin: () => Effect.succeed(false) }),
  Layer.succeed(SnapshotStore, { record: unused, describe: unused, list: unused, markDeleted: unused }),
  Layer.succeed(ApiKeyAdminStore, { insert: unused, list: unused, revoke: unused }),
  Layer.succeed(UpstreamSnapshots, makeUpstreamSnapshots(upstreamConfig)),
  Layer.succeed(UpstreamTerminals, makeUpstreamTerminals(upstreamConfig)),
  makeMemoryMeshStore().layer,
  Layer.succeed(UpstreamMesh, makeUpstreamMesh(upstreamConfig)),
  meshConfigLayer({ experiment: true, tenantIds: [TENANT] }),
);
const { handler } = makeWebHandler(services);
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: handler });
const API = `http://127.0.0.1:${server.port}`;

const api = async (method: string, path: string, body?: unknown): Promise<{ status: number; json: Record<string, unknown>; ms: number }> => {
  const started = performance.now();
  const response = await fetch(API + path, {
    method,
    headers: { authorization: `Bearer ${apiKey}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const text = await response.text();
  return { status: response.status, json: text === "" ? {} : JSON.parse(text), ms: Math.round(performance.now() - started) };
};
const must = async (method: string, path: string, body?: unknown) => {
  const result = await api(method, path, body);
  if (result.status >= 300) throw new Error(`${method} ${path} -> ${result.status} ${JSON.stringify(result.json)}`);
  return result;
};

const agentEnv = { ...process.env, CMUX_VM_API_URL: API, CMUX_VM_API_KEY: apiKey };
// Async: the API server runs in this process, so a blocking spawn would starve it.
const agent = async (args: string[], timeoutMs = 60_000) => {
  const child = Bun.spawn([AGENT, ...args], { env: agentEnv, stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill(), timeoutMs);
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  clearTimeout(timer);
  return { code, stdout, stderr };
};

// ---- the proof ----
const cmux: { meshId?: string; vmId?: string; deviceId?: string; attached?: boolean } = {};
let failed = false;
try {
  if (AGENT === "") throw new Error("usage: bun e2e.ts <cmux-mesh-agent> < key");
  const mesh = await must("POST", "/v1/meshes", { displayName: `cmux-mesh-m1c-${RUN}` });
  cmux.meshId = String(mesh.json["id"]);
  log("mesh", { meshId: cmux.meshId, ipv4Cidr: mesh.json["ipv4Cidr"], ms: mesh.ms });

  const vm = await must("POST", "/v1/vms", { displayName: `cmux-mesh-m1c-${RUN}`, idleTimeoutSeconds: 300 });
  cmux.vmId = String(vm.json["id"]);
  log("vm", { vmId: cmux.vmId, state: vm.json["state"], idleTimeoutSeconds: vm.json["idleTimeoutSeconds"], ms: vm.ms });

  const member = await must("PUT", `/v1/meshes/${cmux.meshId}/vms/${cmux.vmId}`);
  cmux.attached = true;
  log("vm-joined", { ipv4: member.json["ipv4"], ms: member.ms });

  const server8080 =
    "cat > /tmp/m1c.py <<'EOF'\nimport socket,threading\ns=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('0.0.0.0',8080));s.listen(64)\n" +
    "def h(c):\n  d=c.recv(256)\n  c.sendall(b'pong '+d)\n  c.close()\nwhile True:\n  c,_=s.accept();threading.Thread(target=h,args=(c,),daemon=True).start()\nEOF\n" +
    "(setsid python3 /tmp/m1c.py </dev/null >/tmp/m1c.log 2>&1 &) ; sleep 1; ss -ltn | grep -c ':8080 '";
  const exec = await must("POST", `/v1/vms/${cmux.vmId}/exec`, { command: server8080, timeoutMs: 30_000 });
  log("vm-server", { exitCode: exec.json["exitCode"], stdout: String(exec.json["stdout"] ?? "").trim() });

  const keyFile = join(OUT, "device.key");
  const config = join(OUT, "mesh.json");
  const keygen = await agent(["keygen", "--key-file", keyFile]);
  log("keygen", { code: keygen.code, publicKey: keygen.stdout.trim() });
  const enroll = await agent(["enroll", "--key-file", keyFile, "--mesh", cmux.meshId, "--name", "cmux-lawrence-2", "--out", config]);
  log("enroll", { code: enroll.code, stderr: enroll.stderr.slice(0, 400) });
  if (enroll.code !== 0) throw new Error("enroll failed");
  const devices = await must("GET", `/v1/meshes/${cmux.meshId}/devices`);
  const items = Array.isArray(devices.json["items"]) ? devices.json["items"] : [];
  cmux.deviceId = String(items[0]?.id ?? "");

  const acl = (version: number, allow: string[]) =>
    api("PUT", `/v1/meshes/${cmux.meshId}/acl`, { expectedVersion: version, rules: [{ src: [cmux.deviceId], dst: [cmux.vmId], allow }] });
  const first = await acl(0, ["tcp:8080", "icmp"]);
  log("acl", { version: 1, status: first.status, body: first.json, ms: first.ms });
  log("peers", (await must("GET", `/v1/devices/${cmux.deviceId}/peers`)).json);

  const ping = await agent(["ping", "--config", config, "--key-file", keyFile, cmux.vmId, "-c", "5"], 90_000);
  log("ping", { code: ping.code, stdout: ping.stdout.trim().split("\n"), stderr: ping.stderr.trim().split("\n").slice(-3) });
  const tcp = await agent(["tcp", "--config", config, "--key-file", keyFile, cmux.vmId, "8080", "--send", "hello"], 90_000);
  log("tcp", { code: tcp.code, stdout: tcp.stdout.trim(), stderr: tcp.stderr.trim().split("\n").slice(-3) });
  if (ping.code !== 0 || tcp.code !== 0) failed = true;

  // ACL flips: block tcp:8080 (keep icmp), then allow it again, with a probe every 50 ms.
  let version = 1;
  const rounds = 5;
  const flips: Array<{ kind: string; sentAt: number; putMs: number }> = [];
  const probe = spawn(AGENT, ["probe", "--config", config, "--key-file", keyFile, cmux.vmId, "8080", "--interval-ms", "50", "--duration-s", String(rounds * 8 + 6)], { env: agentEnv });
  let probeOut = "";
  probe.stdout.on("data", (chunk) => (probeOut += chunk));
  const probeDone = new Promise((resolve) => probe.on("exit", resolve));
  await Bun.sleep(3000);
  for (let round = 0; round < rounds; round++) {
    for (const [kind, allow] of [["block", ["icmp"]], ["allow", ["tcp:8080", "icmp"]]] as const) {
      const sentAt = Date.now();
      const result = await acl(version, [...allow]);
      if (result.status !== 200) throw new Error(`acl ${kind} -> ${result.status} ${JSON.stringify(result.json)}`);
      version += 1;
      flips.push({ kind, sentAt, putMs: result.ms });
      await Bun.sleep(3500);
    }
  }
  await probeDone;
  const attempts = probeOut
    .split("\n")
    .filter((line) => line.startsWith("{"))
    .map((line) => JSON.parse(line) as { t: number; ok: boolean })
    .sort((a, b) => a.t - b.t);
  writeFileSync(join(OUT, "probe.jsonl"), attempts.map((a) => JSON.stringify(a)).join("\n") + "\n");
  // Time to effect: from the PUT send to the first attempt (by start time) of the final stable run before the next flip.
  const effects = flips.map((flip, index) => {
    const until = flips[index + 1]?.sentAt ?? Number.POSITIVE_INFINITY;
    const window = attempts.filter((a) => a.t >= flip.sentAt - 400 && a.t < until);
    const want = flip.kind === "allow";
    let start: number | null = null;
    for (const a of window) {
      if (a.ok === want) start ??= a.t;
      else start = null;
    }
    return { ...flip, effectMs: start === null ? null : Math.max(0, start - flip.sentAt), attempts: window.length };
  });
  const p = (values: number[], q: number) => values.sort((a, b) => a - b)[Math.min(values.length - 1, Math.floor(q * values.length))];
  for (const kind of ["block", "allow"]) {
    const values = effects.filter((e) => e.kind === kind && e.effectMs !== null).map((e) => e.effectMs ?? 0);
    log("acl-flip", { kind, n: values.length, p50: p([...values], 0.5), max: Math.max(...values), values, putMs: effects.filter((e) => e.kind === kind).map((e) => e.putMs) });
  }
  if (effects.some((e) => e.effectMs === null)) failed = true;
} catch (error) {
  failed = true;
  log("error", { message: String(error).replace(PROVIDER_KEY, "<redacted>") });
} finally {
  // Cleanup through the cmux VM API, by exact cmux id.
  const steps: Array<[string, string]> = [];
  if (cmux.deviceId) steps.push(["DELETE", `/v1/devices/${cmux.deviceId}`]);
  if (cmux.attached) steps.push(["DELETE", `/v1/meshes/${cmux.meshId}/vms/${cmux.vmId}`]);
  if (cmux.vmId) steps.push(["DELETE", `/v1/vms/${cmux.vmId}`]);
  if (cmux.meshId) steps.push(["DELETE", `/v1/meshes/${cmux.meshId}`]);
  for (const [method, path] of steps) {
    let result = await api(method, path).catch((error) => ({ status: 0, json: { error: String(error) }, ms: 0 }));
    for (let attempt = 0; result.status === 409 && attempt < 20; attempt++) {
      await Bun.sleep(3000);
      result = await api(method, path);
    }
    log("cleanup", { path, status: result.status });
    if (result.status !== 204) failed = true;
  }
  for (const path of [cmux.deviceId && `/v1/devices/${cmux.deviceId}`, cmux.vmId && `/v1/vms/${cmux.vmId}`, cmux.meshId && `/v1/meshes/${cmux.meshId}`]) {
    if (!path) continue;
    const status = (await api("GET", path)).status;
    log("cmux-404", { path, status });
    if (status !== 404) failed = true;
  }
  // Every provider id this run created, read by exact id: 404 each (VM deletes can lag; retry 90 s).
  for (const [id, kind] of ledger) {
    let status = 0;
    for (let attempt = 0; attempt < 30; attempt++) {
      status = (await fetch(`${UPSTREAM}/v5/${PATHS[kind]}/${encodeURIComponent(id)}`, { headers: { authorization: `Bearer ${PROVIDER_KEY}` } })).status;
      if (status === 404) break;
      await Bun.sleep(3000);
    }
    record("verify", kind, id, String(status));
    log("provider-404", { kind, id, status });
    if (status !== 404) failed = true;
  }
  writeFileSync(join(OUT, "audit.json"), JSON.stringify(audit, null, 2));
  log("done", { run: RUN, ok: !failed, out: OUT });
  server.stop(true);
  process.exit(failed ? 1 : 0);
}
