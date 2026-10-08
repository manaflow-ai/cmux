// cmux mesh M4 live proof (cx-0op.6, G1): a team member (a Stack session) makes a one-time
// code, a headless device enrolls with it (owned by the member) and pings the VM. The member
// is removed from the team and a signed Stack `team_membership.deleted` webhook arrives: the
// device's tunnel is deleted by its recorded id, the running ping stops, its signed requests
// answer 404, and the time from the webhook to each of these is measured. A retry of the same
// webhook message does nothing (no provider call, no audit row), another message for the same
// removal revokes nothing more, and the shared membership cache no longer holds the member.
// Run on cmux-lawrence-2 by run-m1.sh <sha> m4.ts.
//
// No real Stack: the real session verifier checks JWTs signed by a key pair generated in this
// process, and the real membership client (with the real 60 s positive cache, in memory) asks
// a fake Stack teams API whose team list this script edits. The webhook secret (whsec_) is
// generated here for this run only and signs the deliveries as Stack (Svix) does. No personal
// credentials.
//
// Same guard as e2e.ts and m3.ts: the provider key arrives on stdin and stays in memory; the
// real cmux VM API handlers run in this process with in-memory stores (no database, no
// migration); every provider id the handlers create goes to a ledger at creation; mutating
// calls on any other id are refused; at most 20 live resources; the VM idles out after 300 s;
// cleanup uses a separate admin-scoped cmux API key and deletes by exact cmux id through the
// API, then reads every ledger id from the provider by exact id and expects 404.
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Effect, Layer, Option, Redacted } from "effect";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";
import { makeWebHandler } from "../../src/app.ts";
import { generateApiKey, hashApiKey, makeStackSessionVerifier, makeStackTeamMembership, SessionVerifier, TeamMembership } from "../../src/auth/credentials.ts";
import { makeMemoryMembershipCache, MEMBERSHIP_POSITIVE_TTL_MS } from "../../src/auth/membership-cache.ts";
import { TeamAdmin } from "../../src/auth/team-admin.ts";
import { signWebhookContent } from "../../src/auth/webhook-signature.ts";
import { ApiKeyAdminStore } from "../../src/db/api-keys.ts";
import { makeMemoryWebhookDeliveryStore } from "../../src/db/identity.ts";
import { makeMemoryMeshStore } from "../../src/db/mesh-memory.ts";
import { SnapshotStore } from "../../src/db/snapshots.ts";
import { ApiKeyStore, AuditStore, OwnershipStore, type ApiKeyRecord, type OwnedResource } from "../../src/db/stores.ts";
import { SCOPES } from "../../src/domain/scopes.ts";
import { newApiKeyId, TenantId, UserId } from "../../src/lib/ids.ts";
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
const RUN = `m4${Date.now().toString(36)}`;
const TENANT = `team_mesh_m4_${RUN}`;
const MEMBER = `user_mesh_m4_${RUN}`;
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

/** Every provider call, for "the retry made no provider call". */
let providerCalls = 0;
const countedFetch = async (request: Request): Promise<Response> => {
  if (new URL(request.url).origin === UPSTREAM) providerCalls += 1;
  return guardedFetch(request);
};

// ---- a fake Stack: a local session key and a team list this script edits ----
const STACK_API = "https://stack.m4-proof.invalid";
const STACK_PROJECT = `project-${RUN}`;
const { publicKey, privateKey } = await generateKeyPair("ES256");
const getKey = createLocalJWKSet({ keys: [{ ...(await exportJWK(publicKey)), kid: "m4-proof", alg: "ES256" }] });
const team = new Set<string>([MEMBER]);
const stackCalls: string[] = [];
const fakeStack = async (request: Request): Promise<Response> => {
  const url = new URL(request.url);
  if (url.origin !== STACK_API || url.pathname !== "/api/v1/teams") return Response.json({ message: "no route" }, { status: 404 });
  const user = url.searchParams.get("user_id") ?? "";
  stackCalls.push(user);
  return Response.json({ items: team.has(user) ? [{ id: TENANT }] : [] });
};
const sessionToken = await new SignJWT({ project_id: STACK_PROJECT })
  .setProtectedHeader({ alg: "ES256", kid: "m4-proof" })
  .setSubject(MEMBER)
  .setIssuer(`${STACK_API}/api/v1/projects/${STACK_PROJECT}`)
  .setAudience(STACK_PROJECT)
  .setIssuedAt()
  .setExpirationTime("30m")
  .sign(privateKey);
// The webhook signing secret: 32 random bytes, generated for this run only.
const WEBHOOK_SECRET = `whsec_${btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))))}`;

// ---- the cmux VM API, in process ----
const tenantId = TenantId.make(TENANT);
// The setup key creates the mesh and VM; the cleanup key (admin scope) deletes by exact id at the end.
const setupKey = generateApiKey();
const cleanupKey = generateApiKey();
const keys = new Map<string, ApiKeyRecord>([
  [await Effect.runPromise(hashApiKey(setupKey)), { id: newApiKeyId(), tenantId, scopes: SCOPES.filter((scope) => scope !== "admin"), resourceAllowlist: null, expiresAt: null }],
  [await Effect.runPromise(hashApiKey(cleanupKey)), { id: newApiKeyId(), tenantId, scopes: [...SCOPES], resourceAllowlist: null, expiresAt: null }],
]);
const resources: OwnedResource[] = [];
const deleted = new Set<string>();
const audit: Array<Record<string, unknown>> = [];
const cache = makeMemoryMembershipCache();
const deliveries = makeMemoryWebhookDeliveryStore();
const upstreamConfig = { baseUrl: UPSTREAM, apiKey: Redacted.make(PROVIDER_KEY), fetch: countedFetch };
const unused = () => Effect.die("not used by the M4 proof");
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
    findActiveByHash: (hash) => Effect.sync(() => Option.fromNullable(keys.get(hash))),
    findActiveById: (tenant, id) => Effect.sync(() => Option.fromNullable([...keys.values()].find((key) => key.tenantId === tenant && key.id === id))),
  }),
  tenantPolicyLayer({ environment: "local" }),
  Layer.succeed(Entitlements, { mayCreate: (t) => Effect.succeed(t === tenantId) }),
  memoryLimitsLayer(),
  Layer.succeed(UpstreamClient, makeUpstreamClient(upstreamConfig)),
  Layer.succeed(SessionVerifier, makeStackSessionVerifier({ apiUrl: STACK_API, projectId: STACK_PROJECT, getKey })),
  Layer.succeed(
    TeamMembership,
    makeStackTeamMembership({ apiUrl: STACK_API, projectId: STACK_PROJECT, serverKey: Redacted.make("m4-proof-fake-stack"), cache: cache.service, fetch: fakeStack }),
  ),
  Layer.succeed(TeamAdmin, { isAdmin: () => Effect.succeed(false) }),
  Layer.succeed(SnapshotStore, { record: unused, describe: unused, list: unused, markDeleted: unused }),
  Layer.succeed(ApiKeyAdminStore, { insert: unused, list: unused, revoke: unused }),
  Layer.succeed(UpstreamSnapshots, makeUpstreamSnapshots(upstreamConfig)),
  Layer.succeed(UpstreamTerminals, makeUpstreamTerminals(upstreamConfig)),
  makeMemoryMeshStore().layer,
  cache.layer,
  deliveries.layer,
  Layer.succeed(UpstreamMesh, makeUpstreamMesh(upstreamConfig)),
  meshConfigLayer({ experiment: true, tenantIds: [TENANT] }),
);
const { handler } = makeWebHandler(services, { stackWebhookSecret: Redacted.make(WEBHOOK_SECRET) });
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: handler });
const API = `http://127.0.0.1:${server.port}`;

type Auth = { readonly bearer: string; readonly team?: string } | null;
const SETUP: Auth = { bearer: setupKey };
const CLEANUP: Auth = { bearer: cleanupKey };
const SESSION: Auth = { bearer: sessionToken, team: TENANT };
const api = async (method: string, path: string, body?: unknown, auth: Auth = SETUP): Promise<{ status: number; json: Record<string, unknown>; ms: number }> => {
  const started = performance.now();
  const response = await fetch(API + path, {
    method,
    headers: {
      ...(auth === null ? {} : { authorization: `Bearer ${auth.bearer}` }),
      ...(auth?.team === undefined ? {} : { "x-cmux-team-id": auth.team }),
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const text = await response.text();
  return { status: response.status, json: text === "" ? {} : JSON.parse(text), ms: Math.round(performance.now() - started) };
};
const must = async (method: string, path: string, body?: unknown, auth: Auth = SETUP) => {
  const result = await api(method, path, body, auth);
  if (result.status >= 300) throw new Error(`${method} ${path} -> ${result.status} ${JSON.stringify(result.json)}`);
  return result;
};
/** Sends a Stack webhook signed with this run's secret, as Svix does (a fresh timestamp and signature per attempt). */
const webhook = async (messageId: string, event: unknown) => {
  const body = JSON.stringify(event);
  const timestamp = String(Math.floor(Date.now() / 1000));
  const signature = await signWebhookContent(Redacted.make(WEBHOOK_SECRET), `${messageId}.${timestamp}.${body}`);
  const started = performance.now();
  const response = await fetch(`${API}/v1/webhooks/stack`, {
    method: "POST",
    headers: { "content-type": "application/json", "svix-id": messageId, "svix-timestamp": timestamp, "svix-signature": `v1,${signature ?? ""}` },
    body,
  });
  const text = await response.text();
  return { status: response.status, json: text === "" ? {} : JSON.parse(text), ms: Math.round(performance.now() - started) };
};

// The agent never gets a credential: CMUX_VM_API_KEY is removed from its environment.
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
const cachedMember = () => Effect.runSync(cache.service.fresh(tenantId, UserId.make(MEMBER), new Date(Date.now() - MEMBERSHIP_POSITIVE_TTL_MS)));
const providerStatus = async (kind: Kind, id: string) =>
  (await fetch(`${UPSTREAM}/v5/${PATHS[kind]}/${encodeURIComponent(id)}`, { headers: { authorization: `Bearer ${PROVIDER_KEY}` } })).status;

// ---- the proof ----
const cmux: { meshId?: string; vmId?: string; attached?: boolean; devices: string[] } = { devices: [] };
let failed = false;
const check = (label: string, ok: boolean, data: Record<string, unknown> = {}) => {
  log("check", { label, ok, ...data });
  if (!ok) failed = true;
};
try {
  if (AGENT === "") throw new Error("usage: bun m4.ts <cmux-mesh-agent> < key");
  const mesh = await must("POST", "/v1/meshes", { displayName: `cmux-mesh-m4-${RUN}` });
  cmux.meshId = String(mesh.json["id"]);
  log("mesh", { meshId: cmux.meshId, ipv4Cidr: mesh.json["ipv4Cidr"], ms: mesh.ms });
  const vm = await must("POST", "/v1/vms", { displayName: `cmux-mesh-m4-${RUN}`, idleTimeoutSeconds: 300 });
  cmux.vmId = String(vm.json["id"]);
  log("vm", { vmId: cmux.vmId, state: vm.json["state"], idleTimeoutSeconds: vm.json["idleTimeoutSeconds"], ms: vm.ms });
  const member = await must("PUT", `/v1/meshes/${cmux.meshId}/vms/${cmux.vmId}`);
  cmux.attached = true;
  const vmIpv4 = String(member.json["ipv4"]);
  log("vm-joined", { ipv4: vmIpv4, ms: member.ms });
  const acl = await must("PUT", `/v1/meshes/${cmux.meshId}/acl`, { expectedVersion: 0, rules: [{ src: ["device:*"], dst: [cmux.vmId], allow: ["icmp"] }] });
  log("acl", { version: acl.json["version"], ruleCount: acl.json["ruleCount"] });

  // The member (a Stack session in the team) makes a code; the device enrolls with it and is the member's.
  const issued = await must("POST", `/v1/meshes/${cmux.meshId}/enrollment-codes`, {}, SESSION);
  const keyFile = join(OUT, "device.key");
  const installFile = join(OUT, "device.install.key");
  const config = join(OUT, "mesh-device.json");
  await agent(["keygen", "--key-file", keyFile]);
  await agent(["install-keygen", "--out", installFile]);
  const enroll = await agent(["enroll", "--key-file", keyFile, "--install-key", installFile, "--mesh", cmux.meshId, "--name", "member-laptop", "--out", config], 60_000, {
    ...deviceEnv,
    CMUX_MESH_ENROLL_CODE: String(issued.json["code"]),
  });
  const deviceId = String(lastJson(enroll.stdout)["deviceId"] ?? "");
  log("code-enroll", { code: enroll.code, deviceId, stderr: enroll.stderr.slice(0, 300) });
  if (enroll.code !== 0 || deviceId === "") throw new Error("code enroll failed");
  cmux.devices.push(deviceId);
  const createdBy = resources.find((row) => row.kind === "device" && row.cmuxId === deviceId)?.createdBy;
  check("the device belongs to the member", createdBy === `user:${MEMBER}`, { deviceId, createdBy });
  const tunnelIds = [...ledger].filter(([, kind]) => kind === "tunnel").map(([id]) => id);
  check("one provider tunnel recorded for the device", tunnelIds.length === 1, { tunnels: tunnelIds.length });
  const tunnelId = tunnelIds[0] ?? "";

  // The device works: its signed peer map (this also warms the shared membership cache) and a ping.
  const peers = await agent(["peers", "--config", config, "--install-key", installFile]);
  check("signed peers before removal: ok", peers.code === 0, { stderr: peers.stderr.slice(0, 200) });
  const firstPing = await agent(["ping", "--config", config, "--key-file", keyFile, "--install-key", installFile, cmux.vmId, "-c", "3"], 90_000);
  log("ping", { code: firstPing.code, stdout: firstPing.stdout.trim().split("\n"), stderr: firstPing.stderr.trim().split("\n").slice(-2) });
  check("ping before removal: replies", firstPing.code === 0);
  check("membership cached before removal", cachedMember());

  // A ping running through the webhook: one echo every 100 ms (timeout 300 ms), each line stamped on arrival.
  const pingLines: Array<{ t: number; seq: number; ok: boolean }> = [];
  const running = Bun.spawn(
    [AGENT, "ping", "--config", config, "--key-file", keyFile, "--install-key", installFile, vmIpv4, "-c", "150", "--interval-ms", "100", "--timeout-ms", "300"],
    { env: deviceEnv, stdout: "pipe", stderr: "pipe" },
  );
  const reader = (async () => {
    const decoder = new TextDecoder();
    let buffer = "";
    for await (const chunk of running.stdout) {
      buffer += decoder.decode(chunk);
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const text = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf("\n");
        try {
          const parsed: Record<string, unknown> = JSON.parse(text);
          if (typeof parsed["seq"] === "number") pingLines.push({ t: Date.now(), seq: parsed["seq"], ok: parsed["timeout"] !== true });
        } catch {
          // not a ping line
        }
      }
    }
  })();
  for (let waited = 0; waited < 20_000 && pingLines.filter((line) => line.ok).length < 5; waited += 100) await Bun.sleep(100);
  check("running ping replies before the webhook", pingLines.filter((line) => line.ok).length >= 5, { replies: pingLines.filter((line) => line.ok).length });

  // The member leaves the team (Stack), then Stack sends the signed team_membership.deleted webhook.
  team.delete(MEMBER);
  const messageId = `msg_m4_${RUN}`;
  const event = { type: "team_membership.deleted", data: { team_id: TENANT, user_id: MEMBER } };
  const sentAt = Date.now();
  const delivered = await webhook(messageId, event);
  const answeredAt = Date.now();
  log("webhook", { status: delivered.status, body: delivered.json, ms: delivered.ms });
  check("webhook: 200, one device revoked", delivered.status === 200 && delivered.json["devicesRevoked"] === 1, { body: delivered.json });

  // Measurements: provider tunnel gone (exact recorded id), signed requests 404, the running ping stops.
  let tunnelGoneAt = 0;
  for (let attempt = 0; attempt < 100 && tunnelGoneAt === 0; attempt++) {
    if ((await providerStatus("tunnel", tunnelId)) === 404) tunnelGoneAt = Date.now();
    else await Bun.sleep(100);
  }
  check("provider GET tunnel by recorded id: 404", tunnelGoneAt !== 0, { msAfterWebhookSent: tunnelGoneAt - sentAt });
  const signedAfter = await agent(["peers", "--config", config, "--install-key", installFile]);
  check("signed peers after the webhook: 404", signedAfter.code !== 0 && signedAfter.stderr.includes('"status":404'), { stderr: signedAfter.stderr.trim().slice(0, 200) });
  check("device read by the admin key: 404", (await api("GET", `/v1/devices/${deviceId}`, undefined, CLEANUP)).status === 404);
  for (let waited = 0; waited < 5_000; waited += 100) await Bun.sleep(100);
  const exitedEarly = running.exitCode !== null;
  running.kill();
  const runningExit = await running.exited;
  await reader;
  const runningStderr = (await new Response(running.stderr).text()).trim().split("\n").slice(-2);
  writeFileSync(join(OUT, "ping.jsonl"), pingLines.map((line) => JSON.stringify(line)).join("\n") + "\n");
  const before = pingLines.filter((line) => line.t <= sentAt);
  const after = pingLines.filter((line) => line.t > sentAt);
  const lastReply = [...pingLines].reverse().find((line) => line.ok);
  const firstLoss = after.find((line) => !line.ok);
  const repliesAfterLoss = firstLoss === undefined ? 0 : after.filter((line) => line.ok && line.seq > firstLoss.seq).length;
  log("timing", {
    webhookAnsweredMs: answeredAt - sentAt,
    providerTunnel404Ms: tunnelGoneAt - sentAt,
    lastReplyMsAfterWebhookSent: lastReply === undefined ? null : lastReply.t - sentAt,
    firstLossLineMsAfterWebhookSent: firstLoss === undefined ? null : firstLoss.t - sentAt,
    repliesBefore: before.filter((line) => line.ok).length,
    repliesAfter: after.filter((line) => line.ok).length,
    lossesAfter: after.filter((line) => !line.ok).length,
    repliesAfterFirstLoss: repliesAfterLoss,
    runningPing: { exitedEarly, exit: runningExit, stderr: runningStderr },
  });
  // Stopped: no reply later than 1 s after the provider answered 404 for the tunnel, and either losses or the agent's session ended.
  const lateReplies = pingLines.filter((line) => line.ok && line.t > tunnelGoneAt + 1000).length;
  check("the running ping stopped and did not come back", tunnelGoneAt !== 0 && lateReplies === 0 && repliesAfterLoss === 0 && (firstLoss !== undefined || exitedEarly), { lateReplies });
  const freshPing = await agent(["ping", "--config", config, "--key-file", keyFile, "--install-key", installFile, vmIpv4, "-c", "3", "--timeout-ms", "500"], 60_000);
  log("ping-after", { code: freshPing.code, stdout: freshPing.stdout.trim().split("\n").slice(-1), stderr: freshPing.stderr.trim().split("\n").slice(-1) });
  check("a new ping after the webhook: no reply", freshPing.code !== 0);

  // The shared cache no longer holds the member.
  const row = cache.rows.get(`${TENANT}\u0000${MEMBER}`);
  check("membership cache entry gone (revoked at or after the cached answer)", !cachedMember(), {
    askedAt: row?.askedAt?.toISOString() ?? null,
    revokedAt: row?.revokedAt?.toISOString() ?? null,
  });
  const stackBefore = stackCalls.length;
  check("the member's session is refused (403) and Stack was asked again", (await api("GET", "/v1/meshes", undefined, SESSION)).status === 403 && stackCalls.length === stackBefore + 1);

  // A retry of the same message (fresh Svix timestamp and signature): nothing happens.
  const callsBefore = providerCalls;
  const auditBefore = audit.length;
  const retry = await webhook(messageId, event);
  log("webhook-retry", { status: retry.status, body: retry.json, ms: retry.ms });
  check("retry: 200 duplicate, no provider call, no audit row", retry.status === 200 && retry.json["duplicate"] === true && providerCalls === callsBefore && audit.length === auditBefore, {
    providerCalls: providerCalls - callsBefore,
    auditRows: audit.length - auditBefore,
  });
  // Another message for the same removal: no device left to revoke, no provider mutation.
  const other = await webhook(`${messageId}_b`, event);
  log("webhook-other-message", { status: other.status, body: other.json });
  check("another message for the same removal revokes nothing", other.status === 200 && other.json["devicesRevoked"] === 0);
  const revokeRows = audit.filter((entry) => entry["action"] === "device.revoke");
  check("one device.revoke audit row as the webhook, owner the member", revokeRows.length === 1 && revokeRows[0]?.["actor"] === "system:stack-membership-webhook" && revokeRows[0]?.["ownerActor"] === `user:${MEMBER}`, {
    rows: revokeRows.length,
  });
} catch (error) {
  failed = true;
  log("error", { message: String(error).replace(PROVIDER_KEY, "<redacted>") });
} finally {
  // Cleanup through the cmux VM API with the admin-scoped cleanup key, by exact cmux id. A revoked device is already gone (404).
  const steps: Array<[string, string, ReadonlyArray<number>]> = [];
  for (const deviceId of cmux.devices) steps.push(["DELETE", `/v1/devices/${deviceId}`, [204, 404]]);
  if (cmux.attached) steps.push(["DELETE", `/v1/meshes/${cmux.meshId}/vms/${cmux.vmId}`, [204]]);
  if (cmux.vmId) steps.push(["DELETE", `/v1/vms/${cmux.vmId}`, [204]]);
  if (cmux.meshId) steps.push(["DELETE", `/v1/meshes/${cmux.meshId}`, [204]]);
  for (const [method, path, accepted] of steps) {
    let result = await api(method, path, undefined, CLEANUP).catch((error) => ({ status: 0, json: { error: String(error) }, ms: 0 }));
    for (let attempt = 0; result.status === 409 && attempt < 20; attempt++) {
      await Bun.sleep(3000);
      result = await api(method, path, undefined, CLEANUP);
    }
    log("cleanup", { path, status: result.status });
    if (!accepted.includes(result.status)) failed = true;
  }
  for (const path of [...cmux.devices.map((id) => `/v1/devices/${id}`), cmux.vmId && `/v1/vms/${cmux.vmId}`, cmux.meshId && `/v1/meshes/${cmux.meshId}`]) {
    if (!path) continue;
    const status = (await api("GET", path, undefined, CLEANUP)).status;
    log("cmux-404", { path, status });
    if (status !== 404) failed = true;
  }
  for (const [id, kind] of ledger) {
    let status = 0;
    for (let attempt = 0; attempt < 30; attempt++) {
      status = await providerStatus(kind, id);
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
