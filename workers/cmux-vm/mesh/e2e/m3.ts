// cmux mesh M3 live proof (cx-0op.5): a headless device enrolls with a one-time code made by
// an API key, then reads its own peer map and tunnel config, pings the VM, and rotates its
// WireGuard key with only its install-key signature: no API key in the agent's environment.
// Live negatives on the real handlers: a device's signature for another device (404), a
// replayed signed request (409), a stale one (403), a forged code enroll (403, code burned),
// and the creating API key revoked (the device's signed requests and a fresh code: 404).
// Run on cmux-lawrence-2 by run-m1.sh <sha> m3.ts.
//
// Same guard as e2e.ts: the provider key arrives on stdin and stays in memory; the real
// cmux VM API handlers run in this process with in-memory stores (no database, no
// migration); every provider id the handlers create goes to a ledger at creation;
// mutating calls on any other id are refused; at most 20 live resources; the VM idles out
// after 300 s; cleanup deletes by exact cmux id through the API, then reads every ledger id
// from the provider by exact id and expects 404.
import { appendFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Effect, Layer, Option, Redacted } from "effect";
import { makeWebHandler } from "../../src/app.ts";
import { generateApiKey, hashApiKey, SessionVerifier, TeamMembership } from "../../src/auth/credentials.ts";
import { TeamAdmin } from "../../src/auth/team-admin.ts";
import { ApiKeyAdminStore } from "../../src/db/api-keys.ts";
import { makeMemoryMeshStore } from "../../src/db/mesh-memory.ts";
import { makeMemoryMembershipCache } from "../../src/auth/membership-cache.ts";
import { makeMemoryWebhookDeliveryStore } from "../../src/db/identity.ts";
import { SnapshotStore } from "../../src/db/snapshots.ts";
import { ApiKeyStore, AuditStore, OwnershipStore, type ApiKeyRecord, type OwnedResource } from "../../src/db/stores.ts";
import { SCOPES, type Scope } from "../../src/domain/scopes.ts";
import { newApiKeyId, TenantId, type ApiKeyId } from "../../src/lib/ids.ts";
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
const RUN = `m3${Date.now().toString(36)}`;
const TENANT = `team_mesh_m3_${RUN}`;
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

// ---- provider fetch guard and ledger (as in e2e.ts) ----
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
  const response = await fetch(request);
  if (!response.ok && !(request.method === "GET" && response.status === 404)) {
    log("provider-error", { method: request.method, path: url.pathname.replace(/[^/]{20,}/gu, "<id>"), status: response.status, body: (await response.clone().text()).slice(0, 300) });
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
    if (kind === "tunnel" || kind === "vm") for (const [rid, k] of ledger) if (k === "rule" && live.delete(rid)) record("gone", "rule", rid, `with ${kind}`);
  }
  return response;
};

// ---- the cmux VM API, in process ----
const tenantId = TenantId.make(TENANT);
// The admin key sets up the mesh and VM; the member key makes the enrollment codes, so the
// headless devices belong to it; revoking it must end their signed requests.
const adminKey = generateApiKey();
const memberKey = generateApiKey();
const keys = new Map<string, ApiKeyRecord>([
  // With the admin scope: cleanup must delete the member's devices even after the member key is revoked
  // (run m3muxuf66g left two tunnels and the VPC without it; they were deleted by exact id).
  [await Effect.runPromise(hashApiKey(adminKey)), { id: newApiKeyId(), tenantId, scopes: [...SCOPES], resourceAllowlist: null, expiresAt: null }],
  [await Effect.runPromise(hashApiKey(memberKey)), { id: newApiKeyId(), tenantId, scopes: ["mesh:read", "mesh:join"] satisfies Scope[], resourceAllowlist: null, expiresAt: null }],
]);
const revoked = new Set<ApiKeyId>();
const memberKeyId = [...keys.values()].find((key) => key.scopes.length === 2)?.id;
const resources: OwnedResource[] = [];
const deleted = new Set<string>();
const audit: unknown[] = [];
const upstreamConfig = { baseUrl: UPSTREAM, apiKey: Redacted.make(PROVIDER_KEY), fetch: guardedFetch };
const unused = () => Effect.die("not used by the M3 proof");
const services = Layer.mergeAll(
  Layer.succeed(OwnershipStore, {
    find: (t, kind, id) => Effect.sync(() => Option.fromNullable(resources.find((r) => r.tenantId === t && r.kind === kind && r.cmuxId === id && !deleted.has(id)))),
    record: (resource) => Effect.sync(() => void resources.push(resource)),
    listPage: (t, kind, page) => Effect.sync(() => resources.filter((r) => r.tenantId === t && r.kind === kind && !deleted.has(r.cmuxId)).slice(0, page.limit)),
    countLive: (t, kind) => Effect.sync(() => resources.filter((r) => r.tenantId === t && r.kind === kind && !deleted.has(r.cmuxId)).length),
    markDeleted: (_t, _kind, id) => Effect.sync(() => void deleted.add(id)),
  }),
  Layer.succeed(AuditStore, { append: (entry) => Effect.sync(() => void audit.push({ ...entry, at: entry.at.toISOString() })) }),
  Layer.succeed(ApiKeyStore, {
    findActiveByHash: (hash) => Effect.sync(() => Option.filter(Option.fromNullable(keys.get(hash)), (key) => !revoked.has(key.id))),
    findActiveById: (tenant, id) => Effect.sync(() => Option.fromNullable([...keys.values()].find((key) => key.tenantId === tenant && key.id === id && !revoked.has(key.id)))),
  }),
  tenantPolicyLayer({ environment: "local" }),
  Layer.succeed(Entitlements, { mayCreate: (t) => Effect.succeed(t === tenantId) }),
  memoryLimitsLayer(),
  Layer.succeed(UpstreamClient, makeUpstreamClient(upstreamConfig)),
  Layer.succeed(SessionVerifier, { verify: () => Effect.die("sessions are not used by the M3 proof") }),
  Layer.succeed(TeamMembership, { isMember: () => Effect.succeed(false) }),
  Layer.succeed(TeamAdmin, { isAdmin: () => Effect.succeed(false) }),
  Layer.succeed(SnapshotStore, { record: unused, describe: unused, list: unused, markDeleted: unused }),
  Layer.succeed(ApiKeyAdminStore, { insert: unused, list: unused, revoke: unused }),
  Layer.succeed(UpstreamSnapshots, makeUpstreamSnapshots(upstreamConfig)),
  Layer.succeed(UpstreamTerminals, makeUpstreamTerminals(upstreamConfig)),
  makeMemoryMeshStore().layer,
  // Mesh M4 services (unused by this run).
  makeMemoryMembershipCache().layer,
  makeMemoryWebhookDeliveryStore().layer,
  Layer.succeed(UpstreamMesh, makeUpstreamMesh(upstreamConfig)),
  meshConfigLayer({ experiment: true, tenantIds: [TENANT] }),
);
const { handler } = makeWebHandler(services);
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: handler });
const API = `http://127.0.0.1:${server.port}`;

const api = async (method: string, path: string, body?: unknown, key: string | null = adminKey): Promise<{ status: number; json: Record<string, unknown>; ms: number }> => {
  const started = performance.now();
  const response = await fetch(API + path, {
    method,
    headers: { ...(key === null ? {} : { authorization: `Bearer ${key}` }), ...(body === undefined ? {} : { "content-type": "application/json" }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const text = await response.text();
  return { status: response.status, json: text === "" ? {} : JSON.parse(text), ms: Math.round(performance.now() - started) };
};
const must = async (method: string, path: string, body?: unknown, key: string | null = adminKey) => {
  const result = await api(method, path, body, key);
  if (result.status >= 300) throw new Error(`${method} ${path} -> ${result.status} ${JSON.stringify(result.json)}`);
  return result;
};

// The agent never gets an API key: CMUX_VM_API_KEY is removed from its environment.
const { CMUX_VM_API_KEY: _dropped, ...baseEnv } = process.env;
const deviceEnv = { ...baseEnv, CMUX_VM_API_URL: API };
const agent = async (args: string[], timeoutMs = 60_000, env: Record<string, string | undefined> = deviceEnv) => {
  const child = Bun.spawn([AGENT, ...args], { env, stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill(), timeoutMs);
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  clearTimeout(timer);
  return { code, stdout, stderr };
};
const lastJson = (text: string): Record<string, unknown> => {
  try {
    return JSON.parse(text.trim().split("\n").at(-1) ?? "{}");
  } catch {
    return {};
  }
};

// ---- signing in the script, for the live negatives (the agent's own wire format) ----
const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const b64url = (bytes: Uint8Array) => b64(bytes).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "");
const fromB64 = (text: string) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
/** Loads an agent install key (base64 scalar in a 0600 file) with its public point from install-keygen. */
const loadInstall = async (file: string, publicKey: string) => {
  const point = fromB64(publicKey);
  const jwk = { kty: "EC", crv: "P-256", x: b64url(point.slice(1, 33)), y: b64url(point.slice(33, 65)), d: b64url(fromB64(readFileSync(file, "utf8").trim())) };
  return { publicKey, key: await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]) };
};
const signRead = async (install: { publicKey: string; key: CryptoKey }, purpose: "peers" | "tunnel", deviceId: string, signedAt = Date.now()) => {
  const nonce = b64url(crypto.getRandomValues(new Uint8Array(16)));
  const message = ["cmux-mesh-v1", purpose, deviceId, "", install.publicKey, "", String(signedAt), nonce].join("\n");
  const signature = b64(new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, install.key, new TextEncoder().encode(message))));
  return { signedAt, nonce, signature };
};

// ---- the proof ----
const cmux: { meshId?: string; vmId?: string; attached?: boolean; devices: string[] } = { devices: [] };
let failed = false;
const expectStatus = (label: string, got: number, want: number) => {
  log("check", { label, got, want, ok: got === want });
  if (got !== want) failed = true;
};
try {
  if (AGENT === "" || memberKeyId === undefined) throw new Error("usage: bun m3.ts <cmux-mesh-agent> < key");
  const mesh = await must("POST", "/v1/meshes", { displayName: `cmux-mesh-m3-${RUN}` });
  cmux.meshId = String(mesh.json["id"]);
  log("mesh", { meshId: cmux.meshId, ipv4Cidr: mesh.json["ipv4Cidr"], ms: mesh.ms });
  const vm = await must("POST", "/v1/vms", { displayName: `cmux-mesh-m3-${RUN}`, idleTimeoutSeconds: 300 });
  cmux.vmId = String(vm.json["id"]);
  log("vm", { vmId: cmux.vmId, state: vm.json["state"], idleTimeoutSeconds: vm.json["idleTimeoutSeconds"], ms: vm.ms });
  const member = await must("PUT", `/v1/meshes/${cmux.meshId}/vms/${cmux.vmId}`);
  cmux.attached = true;
  log("vm-joined", { ipv4: member.json["ipv4"], ms: member.ms });
  const acl = await must("PUT", `/v1/meshes/${cmux.meshId}/acl`, { expectedVersion: 0, rules: [{ src: ["device:*"], dst: [cmux.vmId], allow: ["icmp"] }] });
  log("acl", { version: acl.json["version"], ruleCount: acl.json["ruleCount"] });

  // Device A: enrolled with a code the member key made; no API key anywhere in the agent's environment.
  const enrollHeadless = async (label: string) => {
    const issued = await must("POST", `/v1/meshes/${cmux.meshId}/enrollment-codes`, {}, memberKey);
    const keyFile = join(OUT, `${label}.key`);
    const installFile = join(OUT, `${label}.install.key`);
    const config = join(OUT, `mesh-${label}.json`);
    await agent(["keygen", "--key-file", keyFile]);
    const installPublic = (await agent(["install-keygen", "--out", installFile])).stdout.trim();
    const enroll = await agent(["enroll", "--key-file", keyFile, "--install-key", installFile, "--mesh", cmux.meshId ?? "", "--name", label, "--out", config], 60_000, {
      ...deviceEnv,
      CMUX_MESH_ENROLL_CODE: String(issued.json["code"]),
    });
    const deviceId = String(lastJson(enroll.stdout)["deviceId"] ?? "");
    log("code-enroll", { label, code: enroll.code, deviceId, stderr: enroll.stderr.slice(0, 300) });
    if (enroll.code !== 0 || deviceId === "") throw new Error(`code enroll ${label} failed`);
    cmux.devices.push(deviceId);
    return { keyFile, installFile, installPublic, config, deviceId };
  };
  const a = await enrollHeadless("device-a");

  // Its own peer map and tunnel config, signed, no API key.
  const peers = await agent(["peers", "--config", a.config, "--install-key", a.installFile]);
  const peerMap = lastJson(peers.stdout);
  const peerIds = Array.isArray(peerMap["peers"]) ? peerMap["peers"].map((peer: { id?: string }) => peer.id) : [];
  log("signed-peers", { code: peers.code, deviceId: peerMap["deviceId"], aclVersion: peerMap["aclVersion"], peers: peerIds, stderr: peers.stderr.slice(0, 200) });
  if (peers.code !== 0 || !peerIds.includes(cmux.vmId)) failed = true;
  const tunnel = await agent(["tunnel", "--config", a.config, "--install-key", a.installFile]);
  const tunnelConfig = lastJson(tunnel.stdout);
  log("signed-tunnel", { code: tunnel.code, deviceId: tunnelConfig["deviceId"], endpointPort: tunnelConfig["endpointPort"], hasPrivateKey: /PrivateKey|privateKey/u.test(tunnel.stdout), stderr: tunnel.stderr.slice(0, 200) });
  if (tunnel.code !== 0 || tunnelConfig["deviceId"] !== a.deviceId || /PrivateKey|privateKey/u.test(tunnel.stdout)) failed = true;

  // The data plane works, the vm_ id resolved through the signed peer map.
  const ping = await agent(["ping", "--config", a.config, "--key-file", a.keyFile, "--install-key", a.installFile, cmux.vmId, "-c", "3"], 90_000);
  log("ping", { code: ping.code, stdout: ping.stdout.trim().split("\n"), stderr: ping.stderr.trim().split("\n").slice(-2) });
  if (ping.code !== 0) failed = true;

  // Rotation with only the install-key signature, then the new key pings.
  const newKey = join(OUT, "device-a.rot.key");
  const rotated = await agent(["rotate", "--config", a.config, "--key-file", a.keyFile, "--install-key", a.installFile, "--new-key-file", newKey], 30_000);
  const answer = lastJson(rotated.stdout);
  log("signed-rotate", { code: rotated.code, deviceId: answer["deviceId"], rotateMs: Number(answer["respondedAtMs"]) - Number(answer["sentAtMs"]), stderr: rotated.stderr.slice(0, 200) });
  if (rotated.code !== 0) failed = true;
  rmSync(a.keyFile);
  const ping2 = await agent(["ping", "--config", a.config, "--key-file", newKey, "--install-key", a.installFile, cmux.vmId, "-c", "3"], 90_000);
  log("ping-after-rotate", { code: ping2.code, stdout: ping2.stdout.trim().split("\n"), stderr: ping2.stderr.trim().split("\n").slice(-2) });
  if (ping2.code !== 0) failed = true;

  // Live negatives against the real handlers.
  const b = await enrollHeadless("device-b");
  const installA = await loadInstall(a.installFile, a.installPublic);
  const installB = await loadInstall(b.installFile, b.installPublic);
  expectStatus("A signs for B: 404", (await api("POST", `/v1/devices/${b.deviceId}/signed/peers`, await signRead(installA, "peers", b.deviceId), null)).status, 404);
  expectStatus("A's own request sent to B's path: 404", (await api("POST", `/v1/devices/${b.deviceId}/signed/tunnel`, await signRead(installA, "tunnel", a.deviceId), null)).status, 404);
  const once = await signRead(installB, "peers", b.deviceId);
  expectStatus("B signed peers: 200", (await api("POST", `/v1/devices/${b.deviceId}/signed/peers`, once, null)).status, 200);
  expectStatus("B replayed: 409", (await api("POST", `/v1/devices/${b.deviceId}/signed/peers`, once, null)).status, 409);
  expectStatus("B stale: 403", (await api("POST", `/v1/devices/${b.deviceId}/signed/peers`, await signRead(installB, "peers", b.deviceId, Date.now() - 10 * 60_000), null)).status, 403);
  expectStatus("no credential on the bearer route: 401", (await api("GET", `/v1/devices/${b.deviceId}/peers`, undefined, null)).status, 401);

  // A forged code enroll (a body signed by another key than the one it names) burns the code.
  const forgedCode = String((await must("POST", `/v1/meshes/${cmux.meshId}/enrollment-codes`, {}, memberKey)).json["code"]);
  const forgedNonce = b64url(crypto.getRandomValues(new Uint8Array(16)));
  const forgedAt = Date.now();
  const wg = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDk=";
  const forgedMessage = ["cmux-mesh-v1", "enroll", cmux.meshId, wg, installA.publicKey, "forged", String(forgedAt), forgedNonce].join("\n");
  const forgedSignature = b64(new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, installB.key, new TextEncoder().encode(forgedMessage))));
  const forgedBody = { code: forgedCode, name: "forged", wgPublicKey: wg, installPublicKey: installA.publicKey, signedAt: forgedAt, nonce: forgedNonce, signature: forgedSignature };
  expectStatus("forged code enroll: 403", (await api("POST", `/v1/meshes/${cmux.meshId}/device-enrollments`, forgedBody, null)).status, 403);
  const retryAt = Date.now();
  const retryNonce = b64url(crypto.getRandomValues(new Uint8Array(16)));
  const retryMessage = ["cmux-mesh-v1", "enroll", cmux.meshId, wg, installA.publicKey, "forged", String(retryAt), retryNonce].join("\n");
  const retrySignature = b64(new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, installA.key, new TextEncoder().encode(retryMessage))));
  expectStatus(
    "the burned code with a valid signature: 404",
    (await api("POST", `/v1/meshes/${cmux.meshId}/device-enrollments`, { ...forgedBody, signedAt: retryAt, nonce: retryNonce, signature: retrySignature }, null)).status,
    404,
  );

  // Revoke the member key: its devices' signed requests and its unused codes stop.
  const lateCode = String((await must("POST", `/v1/meshes/${cmux.meshId}/enrollment-codes`, {}, memberKey)).json["code"]);
  revoked.add(memberKeyId);
  log("revoke", { key: "member" });
  const revokedPeers = await agent(["peers", "--config", a.config, "--install-key", a.installFile]);
  log("signed-peers-after-revoke", { code: revokedPeers.code, stderr: revokedPeers.stderr.trim().slice(0, 200) });
  if (revokedPeers.code === 0 || !revokedPeers.stderr.includes('"status":404')) failed = true;
  expectStatus("B signed peers after revoke: 404", (await api("POST", `/v1/devices/${b.deviceId}/signed/peers`, await signRead(installB, "peers", b.deviceId), null)).status, 404);
  await agent(["keygen", "--key-file", join(OUT, "late.key")]);
  await agent(["install-keygen", "--out", join(OUT, "late.install.key")]);
  const lateEnroll = await agent(
    ["enroll", "--key-file", join(OUT, "late.key"), "--install-key", join(OUT, "late.install.key"), "--mesh", cmux.meshId, "--name", "late", "--out", join(OUT, "mesh-late.json")],
    60_000,
    { ...deviceEnv, CMUX_MESH_ENROLL_CODE: lateCode },
  );
  log("code-enroll-after-revoke", { code: lateEnroll.code, stderr: lateEnroll.stderr.trim().slice(0, 200) });
  if (lateEnroll.code === 0 || !lateEnroll.stderr.includes('"status":404')) failed = true;
} catch (error) {
  failed = true;
  log("error", { message: String(error).replace(PROVIDER_KEY, "<redacted>") });
} finally {
  // Cleanup through the cmux VM API (admin key: an admin may delete any device), by exact cmux id.
  const steps: Array<[string, string]> = [];
  for (const deviceId of cmux.devices) steps.push(["DELETE", `/v1/devices/${deviceId}`]);
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
  for (const path of [...cmux.devices.map((id) => `/v1/devices/${id}`), cmux.vmId && `/v1/vms/${cmux.vmId}`, cmux.meshId && `/v1/meshes/${cmux.meshId}`]) {
    if (!path) continue;
    const status = (await api("GET", path)).status;
    log("cmux-404", { path, status });
    if (status !== 404) failed = true;
  }
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
