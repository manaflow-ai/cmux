import { expect, test, afterAll, beforeAll } from "bun:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { join } from "node:path";

let mf: Miniflare;
let stub: DurableObjectStub;
let storageNamespace: DurableObjectNamespace;
let migrationNamespace: DurableObjectNamespace;
let workerRoot = "";
let persistencePath = "";

const identity = { environment: "test", projectId: "iroh-v2-test", teamId: "team-e2e", userId: "u1", deviceId: "d1", appNamespace: "cmux", buildTag: "test" };
const descriptor = { identity, endpointId: "a".repeat(64), identityGeneration: 0, metadata: { platform: "mac", displayName: "Mac", appVersion: "1", pairingEnabled: true, capabilities: [], relayURLs: [] } };
const post = async (path: string, body: unknown) => {
  const response = await stub.fetch(`https://storage.test${path}`, { method: "POST", body: JSON.stringify(body) });
  return { status: response.status, body: await response.json() as any };
};
const postTo = async (target: DurableObjectStub, path: string, body: unknown) => {
  const response = await target.fetch(`https://storage.test${path}`, { method: "POST", body: JSON.stringify(body) });
  return { status: response.status, body: await response.json() as any };
};
const deviceKey = (character: string) => character.repeat(64);
const reserve = (userId: string, teamId: string, sessionId: string, key = deviceKey("e")) => post("/socket/reserve", { input: { userId, teamId, sessionId, deviceKey: key } });
const output = (userId: string, sessionId: string, revision: number, bytes: number, messages: number) => post("/socket/output", { userId, sessionId, revision, bytes, messages });

beforeAll(async () => {
  const outputDir = `/tmp/iroh-v2-storage-worker-build-${Date.now()}`;
  const bundle = `${outputDir}/worker.js`;
  workerRoot = outputDir;
  persistencePath = `/tmp/iroh-v2-storage-persist-${Date.now()}`;
  const build = Bun.spawnSync({ cmd: ["bun", "build", join(import.meta.dir, "storage-worker.ts"), "--outfile", bundle, "--target", "browser", "--external", "cloudflare:workers"], cwd: process.cwd(), stdout: "pipe", stderr: "pipe" });
  if (build.exitCode !== 0) throw new Error(new TextDecoder().decode(build.stderr));
  mf = new Miniflare({ ...convertV4MiniflareOptions({ rootPath: workerRoot, resourcePersistencePath: persistencePath, scriptPath: "worker.js", modules: true, durableObjects: { STORAGE: { className: "StorageTestDO", useSQLite: true }, MIGRATION: { className: "MigrationProbeDO", useSQLite: true } }, compatibilityDate: "2025-01-01" }), verbose: true });
  storageNamespace = await mf.getDurableObjectNamespace("STORAGE");
  stub = storageNamespace.getByName("team-e2e");
  migrationNamespace = await mf.getDurableObjectNamespace("MIGRATION");
});

afterAll(async () => { await mf?.dispose(); });

test("workerd SQLite persists registration and keeps one challenge/receipt slot", async () => {
  const issue = await post("/issue", { identity, issue: { challengeId: "c1", nonceHash: "n1", payloadHash: "p1", expiresAt: 2000, issuedAt: 1000 } });
  expect(issue.status).toBe(200);
  expect((await post("/issue", { identity, issue: { challengeId: "c2", nonceHash: "n2", payloadHash: "p2", expiresAt: 3000, issuedAt: 2000 } })).status).toBe(200);
  expect((await post("/validate", { input: { descriptor, challengeId: "c1", nonceHash: "n1", payloadHash: "p1", requestId: "r1", requestHash: "h1", now: 2000 } })).status).toBe(500);
  const commit = await post("/register", { input: { descriptor, challengeId: "c2", nonceHash: "n2", payloadHash: "p2", requestId: "r1", requestHash: "h1", now: 2001 } });
  expect(commit.status).toBe(200);
  expect((await post("/register", { input: { descriptor, challengeId: "c2", nonceHash: "n2", payloadHash: "p2", requestId: "r1", requestHash: "h1", now: 2001 } })).body.idempotent).toBe(true);
  expect((await post("/proof", { input: { identity, endpointId: descriptor.endpointId, identityGeneration: 0, requestId: "proof-1", issuedAt: 2001, now: 2001 } })).status).toBe(200);
  expect((await post("/proof", { input: { identity, endpointId: descriptor.endpointId, identityGeneration: 0, requestId: "proof-1", issuedAt: 2001, now: 2001 } })).status).toBe(500);
  expect((await post("/revoke", { deviceRecordId: commit.body.device.deviceRecordId, now: 2002, actorUserId: "u1" })).status).toBe(200);
  expect((await post("/issue", { identity, issue: { challengeId: "c-recover", nonceHash: "n-recover", payloadHash: "p-recover", expiresAt: 4000, issuedAt: 3000 } })).status).toBe(200);
  const recovery = await post("/register", { input: { descriptor, challengeId: "c-recover", nonceHash: "n-recover", payloadHash: "p-recover", requestId: "r-recover", requestHash: "h-recover", now: 3001 } });
  expect(recovery.status).toBe(200);
  expect(recovery.body.device.revoked).toBe(false);
  expect((await post("/proof", { input: { identity, endpointId: descriptor.endpointId, identityGeneration: 0, requestId: "proof-recovery", issuedAt: 3001, now: 3001 } })).status).toBe(200);
  expect((await post("/revision", {})).body.revision).toBe(3);
});

test("an administrator revocation cannot be undone by a pending enrollment", async () => {
  const isolated = (await mf.getDurableObjectNamespace("STORAGE")).getByName("admin-recovery");
  const post = async (path: string, body: unknown) => {
    const response = await isolated.fetch(`https://storage.test${path}`, { method: "POST", body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() as any };
  };
  const device = { ...descriptor, identity: { ...identity, deviceId: "admin-revoked" }, endpointId: "9".repeat(64) };
  const issue = { challengeId: "admin-initial", nonceHash: "admin-nonce", payloadHash: "admin-payload", expiresAt: 4000, issuedAt: 2000 };
  expect((await post("/issue", { identity: device.identity, issue })).status).toBe(200);
  const input = { descriptor: device, challengeId: issue.challengeId, nonceHash: issue.nonceHash, payloadHash: issue.payloadHash, requestId: "admin-initial", requestHash: "admin-initial-hash", now: 2001 };
  const registered = await post("/register", { input });
  expect(registered.status).toBe(200);
  expect((await post("/issue", { identity: device.identity, issue: { ...issue, challengeId: "pending-recovery" } })).status).toBe(200);
  expect((await post("/revoke", { deviceRecordId: registered.body.device.deviceRecordId, now: 2002, actorUserId: "administrator" })).status).toBe(200);
  const result = await post("/register", { input: { ...input, challengeId: "pending-recovery", requestId: "pending-recovery", requestHash: "pending-hash", now: 2003 } });
  expect(result.status).toBe(500);
  expect(result.body.code).toBe("device_revoked");
});

test("failed enrollment leaves its challenge available for retry", async () => {
  const identity2 = { ...identity, deviceId: "d2" };
  const descriptor2 = { ...descriptor, identity: identity2, endpointId: "c".repeat(64) };
  const issue = await post("/issue", { identity: identity2, issue: { challengeId: "c3", nonceHash: "n3", payloadHash: "p3", expiresAt: 4000, issuedAt: 3000 } });
  expect(issue.status).toBe(200);
  expect((await post("/register", { input: { descriptor: descriptor2, challengeId: "c3", nonceHash: "n3", payloadHash: "p3", requestId: "r3", requestHash: "h3", now: 3001 } })).status).toBe(200);
  expect((await post("/issue", { identity: identity2, issue: { challengeId: "c4", nonceHash: "n4", payloadHash: "p4", expiresAt: 5000, issuedAt: 4000 } })).status).toBe(200);
  const wrong = { ...descriptor2, endpointId: "b".repeat(64), identityGeneration: 1 };
  expect((await post("/register", { input: { descriptor: wrong, challengeId: "c4", nonceHash: "n4", payloadHash: "p4", requestId: "r4", requestHash: "h4", now: 4001 } })).status).toBe(500);
  expect((await post("/register", { input: { descriptor: descriptor2, challengeId: "c4", nonceHash: "n4", payloadHash: "p4", requestId: "r4", requestHash: "h4", now: 4001 } })).status).toBe(200);
});

test("challenge expiry rejects at the exact deadline", async () => {
  const identity3 = { ...identity, deviceId: "d3" };
  const descriptor3 = { ...descriptor, identity: identity3, endpointId: "d".repeat(64) };
  expect((await post("/issue", { identity: identity3, issue: { challengeId: "c-exp", nonceHash: "n-exp", payloadHash: "p-exp", expiresAt: 6000, issuedAt: 5990 } })).status).toBe(200);
  expect((await post("/register", { input: { descriptor: descriptor3, challengeId: "c-exp", nonceHash: "n-exp", payloadHash: "p-exp", requestId: "r-exp", requestHash: "h-exp", now: 6000 } })).status).toBe(500);
});

test("pending challenge replacement remains available at the storage cap", async () => {
  expect((await post("/fill-challenges", {})).status).toBe(200);
  const replacementIdentity = {
    ...identity,
    userId: "fill-user-0",
    deviceId: "fill-device-0",
    buildTag: "fill",
  };
  expect((await post("/issue", {
    identity: replacementIdentity,
    issue: {
      challengeId: "fill-replaced",
      nonceHash: "fill-replaced-nonce",
      payloadHash: "fill-replaced-payload",
      issuedAt: 12000,
      expiresAt: 15000,
    },
  })).status).toBe(200);
});

test("workerd usage bucket persists and rejects unknown operations", async () => {
  const first = await post("/usage", { userId: "u1", operation: "device.register", nowMs: 0 });
  expect(first.body.remaining).toBe(49);
  const unknown = await post("/usage", { userId: "u1", operation: "made.up", nowMs: 0 });
  expect(unknown.status).toBe(500);
});

const migrationPost = async (name: string, path: string, body: unknown = {}) => {
  const probe = migrationNamespace.getByName(name);
  const response = await probe.fetch(`https://migration.test${path}`, { method: "POST", body: JSON.stringify(body) });
  return { status: response.status, body: await response.json() as any };
};

test("runtime migration rejects history gaps, future versions, and hash changes", async () => {
  for (const mode of ["gap", "future", "wrong-hash", "wrong-audit-hash"]) {
    expect((await migrationPost(`history-${mode}`, "/seed")).status).toBe(200);
    expect((await migrationPost(`history-${mode}`, "/corrupt", { mode })).status).toBe(200);
    const rejected = await migrationPost(`history-${mode}`, "/migrate");
    expect(rejected.status).toBe(500);
    expect(rejected.body.code).toMatch(/iroh_v2_(unsupported_schema_history|schema_migration_hash_mismatch)/);
  }
});

test("audit usage migration backfills a v6 storage history", async () => {
  const name = "audit-usage-v6";
  expect((await migrationPost(name, "/seed")).status).toBe(200);
  expect((await migrationPost(name, "/downgrade-audit")).status).toBe(200);
  const migrated = await migrationPost(name, "/migrate");
  expect(migrated.status).toBe(200);
  const inspected = await migrationPost(name, "/inspect");
  expect(inspected.body.history.some((row: any) => row.version === 7)).toBe(true);
  expect(inspected.body.auditUsage.row_count).toBe(2);
});

test("failed upgrade rolls back without version marker or partial table", async () => {
  const name = "failed-upgrade";
  expect((await migrationPost(name, "/seed")).status).toBe(200);
  expect((await migrationPost(name, "/corrupt", { mode: "failed-upgrade" })).status).toBe(200);
  expect((await migrationPost(name, "/migrate")).status).toBe(500);
  const inspected = await migrationPost(name, "/inspect");
  expect(inspected.body.history.some((row: any) => row.version === 5)).toBe(false);
  expect(inspected.body.objects.some((row: any) => row.name === "user_authority" && row.type === "table")).toBe(false);
});

test("authority lease accepts newer verification and ignores stale updates", async () => {
  const first = await post("/authority/observe", { userId: "authority-user", verifiedAt: 1000, expiresAt: 4600, now: 1000 });
  expect(first.status).toBe(200);
  expect(first.body.revision).not.toBeNull();
  expect(first.body.revision).toBe(6);
  expect((await post("/authority/get", { userId: "authority-user" })).body).toMatchObject({ verifiedAt: 1000, expiresAt: 4600 });
  expect((await post("/authority/observe", { userId: "authority-user", verifiedAt: 900, expiresAt: 4500, now: 1000 })).body.revision).toBeNull();
  const renewed = await post("/authority/observe", { userId: "authority-user", verifiedAt: 2000, expiresAt: 5600, now: 2000 });
  expect(renewed.body.revision).not.toBeNull();
  expect(renewed.body.revision).toBe(7);
  expect(renewed.body.revision).toBeGreaterThan(first.body.revision);
  expect((await post("/authority/get", { userId: "authority-user" })).body).toMatchObject({ verifiedAt: 2000, expiresAt: 5600 });
  expect((await post("/authority/observe", { userId: "authority-user", verifiedAt: 3000, expiresAt: 6601, now: 3000 })).status).toBe(500);
  expect((await post("/authority/observe", { userId: "authority-user", verifiedAt: 3000, expiresAt: 6600, now: 6600 })).status).toBe(500);
});

test("existing v6 storage serves directory and relay renewal operations after activation", async () => {
  const renewalStub = storageNamespace.getByName("authority-renewal-v6");
  const renewalPost = (path: string, body: unknown = {}) => postTo(renewalStub, path, body);
  expect((await renewalPost("/upgrade-schema", { version: 6 })).status).toBe(200);
  const renewalIdentity = { ...identity, userId: "renewal-user", deviceId: "renewal-device" };
  const renewalDescriptor = { ...descriptor, identity: renewalIdentity, endpointId: "1".repeat(64) };
  const challenge = { challengeId: "renewal-challenge", nonceHash: "renewal-nonce", payloadHash: "renewal-payload", expiresAt: 10_000, issuedAt: 9_000 };
  expect((await renewalPost("/issue", { identity: renewalIdentity, issue: challenge })).status).toBe(200);
  const registration = await renewalPost("/register", { input: { descriptor: renewalDescriptor, ...challenge, requestId: "renewal-register", requestHash: "renewal-hash", now: 9_001 } });
  expect(registration.status).toBe(200);
  const first = await renewalPost("/authority/renewal", { userId: renewalIdentity.userId, verifiedAt: 9_100, expiresAt: 12_700, now: 9_100, requester: registration.body.device });
  expect(first.status).toBe(200);
  expect(first.body.revision).toBeNumber();
  expect(first.body.revision).toBeGreaterThan(registration.body.device.revision);
  expect((await renewalPost("/authority/get", { userId: renewalIdentity.userId })).body).toMatchObject({ verifiedAt: 9_100, expiresAt: 12_700 });
  expect(first.body.devices).toBe(1);
  const second = await renewalPost("/authority/renewal", { userId: renewalIdentity.userId, verifiedAt: 10_100, expiresAt: 13_700, now: 10_100, requester: registration.body.device });
  expect(second.status).toBe(200);
  expect(first.body.revision).not.toBeNull();
  expect(second.body.revision).not.toBeNull();
  expect(second.body.revision).toBeGreaterThan(first.body.revision);
  expect(second.body.devices).toBe(1);
  expect((await renewalPost("/authority/get", { userId: renewalIdentity.userId })).body).toMatchObject({ verifiedAt: 10_100, expiresAt: 13_700 });
});

test.each([6, 7])("a full schema %i audit ring does not turn authority renewal into internal_error", async (version) => {
  const auditStub = storageNamespace.getByName(`authority-renewal-${version}-at-cap`);
  const auditPost = (path: string, body: unknown = {}) => postTo(auditStub, path, body);
  expect((await auditPost("/upgrade-schema", { version })).status).toBe(200);
  const renewalIdentity = { ...identity, userId: "renewal-cap-user", deviceId: "renewal-cap-device" };
  const renewalDescriptor = { ...descriptor, identity: renewalIdentity, endpointId: "2".repeat(64) };
  const challenge = { challengeId: "renewal-cap-challenge", nonceHash: "renewal-cap-nonce", payloadHash: "renewal-cap-payload", expiresAt: 10_000, issuedAt: 9_000 };
  expect((await auditPost("/issue", { identity: renewalIdentity, issue: challenge })).status).toBe(200);
  const registration = await auditPost("/register", { input: { descriptor: renewalDescriptor, ...challenge, requestId: "renewal-cap-register", requestHash: "renewal-cap-hash", now: 9_001 } });
  expect(registration.status).toBe(200);
  expect((await auditPost("/audit/fill")).status).toBe(200);
  const previousRevision = (await auditPost("/revision")).body.revision;
  const renewal = await auditPost("/authority/renewal", { userId: renewalIdentity.userId, verifiedAt: 9_100, expiresAt: 12_700, now: 9_100, requester: registration.body.device });
  expect(renewal.status).toBe(200);
  expect(renewal.body.revision).toBeNumber();
  expect(renewal.body.revision).toBeGreaterThan(previousRevision);
  expect(renewal.body.devices).toBe(1);
  expect((await auditPost("/authority/get", { userId: renewalIdentity.userId })).body).toMatchObject({ verifiedAt: 9_100, expiresAt: 12_700 });
  expect((await auditPost("/audit/count")).body.count).toBe(65_536);
});

test.each([6, 7])("schema %i: audit retention keeps revocation available at the bounded history limit", async (version) => {
  // This test owns a fresh DO. It does not depend on the registration/revision
  // state built by the other cases in this file.
  const auditStub = storageNamespace.getByName("audit-retention-rollback-" + version);
  const auditPost = (path: string, body: unknown = {}) => postTo(auditStub, path, body);
  expect((await auditPost("/upgrade-schema", {version})).status).toBe(200);
  const targetIdentity = { ...identity, userId: "audit-test", deviceId: "revocation-device" };
  const targetDescriptor = { ...descriptor, identity: targetIdentity, endpointId: "f".repeat(64) };
  const targetIssue = { challengeId: "audit-target", nonceHash: "audit-target-nonce", payloadHash: "audit-target-payload", expiresAt: 7000, issuedAt: 6000 };
  expect((await auditPost("/issue", { identity: targetIdentity, issue: targetIssue })).status).toBe(200);
  const registration = await auditPost("/register", { input: { descriptor: targetDescriptor, ...targetIssue, requestId: "audit-target-request", requestHash: "audit-target-hash", now: 6001 } });
  expect(registration.status).toBe(200);
  const targetRecordId = registration.body.device.deviceRecordId;
  expect((await auditPost("/audit/fill")).status).toBe(200);
  expect((await auditPost("/audit/count")).body.count).toBe(65536);
  const oversized = Array.from({ length: 16 }, () => "x".repeat(2048));
  // The oversized audit detail fails after appendAudit has pruned one row.
  // The transaction must restore both the preference write and that row.
  expect((await auditPost("/preferences", { relayURLs: oversized, expectedRevision: 0, now: 7000 })).status).toBe(500);
  expect((await auditPost("/audit/count")).body.count).toBe(65536);
  expect((await auditPost("/audit/usage")).body.count).toBe(65536);
  expect((await auditPost("/audit/first")).body.targetId).toBe(targetRecordId);
  const revoked = await auditPost("/revoke", { deviceRecordId: targetRecordId, now: 7000, actorUserId: "audit-test" });
  expect(revoked.status).toBe(200);
  expect((await auditPost("/device", { deviceRecordId: targetRecordId })).body.revoked).toBe(true);
  expect((await auditPost("/audit/count")).body.count).toBe(65536);
  expect((await auditPost("/audit/usage")).body.count).toBe(65536);
});

test("SQLite state survives a workerd restart", async () => {
  await mf.dispose();
  mf = new Miniflare({ ...convertV4MiniflareOptions({ rootPath: workerRoot, resourcePersistencePath: persistencePath, scriptPath: "worker.js", modules: true, durableObjects: { STORAGE: { className: "StorageTestDO", useSQLite: true }, MIGRATION: { className: "MigrationProbeDO", useSQLite: true } }, compatibilityDate: "2025-01-01" }), verbose: true });
  const namespace = await mf.getDurableObjectNamespace("STORAGE");
  stub = namespace.getByName("team-e2e");
  expect((await post("/revision", {})).body.revision).toBe(7);
});

test("socket reservations aggregate across teams and survive retries", async () => {
  const user = "socket-user";
  expect((await reserve(user, "team-a", "a1", deviceKey("a"))).status).toBe(200);
  expect((await reserve(user, "team-b", "b1", deviceKey("b"))).status).toBe(200);
  expect((await output(user, "a1", 1, 2 * 1024 * 1024, 1024)).status).toBe(200);
  expect((await output(user, "b1", 1, 2 * 1024 * 1024, 1024)).status).toBe(200);
  expect((await reserve(user, "team-a", "a1", deviceKey("a"))).status).toBe(200);
  expect((await reserve(user, "team-a", "a2", deviceKey("a"))).status).toBe(200);
  expect((await reserve(user, "team-b", "b2", deviceKey("b"))).status).toBe(200);
  expect((await output(user, "a2", 1, 2 * 1024 * 1024, 1024)).status).toBe(200);
  expect((await output(user, "b2", 1, 2 * 1024 * 1024, 1024)).status).toBe(200);
  expect((await reserve(user, "team-a", "a3", deviceKey("a"))).status).toBe(200);
  expect(await output(user, "a3", 1, 1, 1)).toEqual({ status: 500, body: { code: "slow_consumer" } });
  expect(await output(user, "a1", 3, 1, 1)).toEqual({ status: 500, body: { code: "revision_conflict" } });
  expect((await post("/socket/release", { userId: user, sessionId: "a1" })).status).toBe(200);
  expect((await post("/socket/release", { userId: user, sessionId: "a1" })).status).toBe(200);
  expect((await post("/socket/list", { userId: user })).body.length).toBe(4);
});

test("different users have independent socket output and connection limits", async () => {
  expect((await reserve("socket-user-2", "team-c", "s1", deviceKey("c"))).status).toBe(200);
  expect((await output("socket-user-2", "s1", 1, 2 * 1024 * 1024, 1024)).status).toBe(200);
  expect((await reserve("socket-user-3", "team-c", "s1", deviceKey("d"))).status).toBe(200);
  expect((await output("socket-user-3", "s1", 1, 2 * 1024 * 1024, 1024)).status).toBe(200);
  const fullUser = "socket-capacity";
  for (let index = 0; index < 500; index += 1) expect((await reserve(fullUser, "team-cap", `s-${index}`)).status).toBe(200);
  expect((await reserve(fullUser, "team-cap", "replacement", deviceKey("e"))).status).toBe(200);
  expect(await reserve(fullUser, "team-cap", "overflow", deviceKey("f"))).toEqual({ status: 500, body: { code: "rate_limited" } });
});

test("socket reservations survive a second workerd restart", async () => {
  await mf.dispose();
  mf = new Miniflare({ ...convertV4MiniflareOptions({ rootPath: workerRoot, resourcePersistencePath: persistencePath, scriptPath: "worker.js", modules: true, durableObjects: { STORAGE: { className: "StorageTestDO", useSQLite: true }, MIGRATION: { className: "MigrationProbeDO", useSQLite: true } }, compatibilityDate: "2025-01-01" }), verbose: true });
  const namespace = await mf.getDurableObjectNamespace("STORAGE");
  stub = namespace.getByName("team-e2e");
  expect((await post("/socket/list", { userId: "socket-capacity" })).body.length).toBe(501);
});
test("administrative revocation after recovery validation cannot be cleared by registration", async () => {
  const recoveryIdentity = { ...identity, deviceId: "revocation-race" };
  const recoveryDescriptor = { ...descriptor, identity: recoveryIdentity, endpointId: "f".repeat(64) };
  const initial = { descriptor: recoveryDescriptor, challengeId: "race-initial", nonceHash: "race-nonce", payloadHash: "race-payload", requestId: "race-enroll", requestHash: "race-enroll-hash", now: 2001 };
  expect((await post("/issue", { identity: recoveryIdentity, issue: { ...initial, expiresAt: 3000, issuedAt: 2000 } })).status).toBe(200);
  const enrolled = await post("/register", { input: initial });
  expect(enrolled.status).toBe(200);
  const deviceRecordId = enrolled.body.device.deviceRecordId;
  expect((await post("/revoke", { deviceRecordId, now: 2002, actorUserId: identity.userId })).status).toBe(200);
  const recovery = { ...initial, challengeId: "race-recovery", requestId: "race-recover", requestHash: "race-recover-hash", now: 3001 };
  expect((await post("/issue", { identity: recoveryIdentity, issue: { ...recovery, expiresAt: 4000, issuedAt: 3000 } })).status).toBe(200);
  expect((await post("/validate", { input: recovery })).status).toBe(200);

  // Model the interleaving while TeamBroker.register awaits ownership.reserve.
  const revoked = await post("/revoke", { deviceRecordId, now: 3002, actorUserId: "team-admin" });
  expect(revoked.status).toBe(200);
  const result = await post("/register", { input: { ...recovery, now: 3003 } });
  expect(result.status).toBe(500); // The storage harness exposes OperationError as 500.
  expect(result.body.code).toBe("device_revoked");
  expect((await post("/revision", {})).body.revision).toBe(revoked.body.revision);
  expect((await post("/receipt", { identity: recoveryIdentity, requestId: recovery.requestId, requestHash: recovery.requestHash })).body).toBeNull();
  expect((await post("/validate", { input: { ...recovery, now: 3003 } })).status).toBe(200);
});


test("ordinary activation retains schema 6 so the deployed reader can reopen it", async () => {
  const result = await post("/schema", {});
  expect(result.status).toBe(200);
  expect(result.body.map((row: any) => row.version)).toEqual([1, 2, 3, 4, 5, 6]);
});


test("reader-first rollout preserves devices and can reopen both schemas without downgrading", async () => {
  const namespace = await mf.getDurableObjectNamespace("STORAGE");
  const stub = namespace.getByName("reader-first-upgrade");
  const request = (path: string, body: unknown = {}) => postTo(stub, path, body);
  const challenge = {challengeId: "upgrade", nonceHash: "n", payloadHash: "p", issuedAt: 100, expiresAt: 200};
  await request("/issue", {identity, issue: challenge});
  const registered = await request("/register", {input: {descriptor, ...challenge, requestId: "r", requestHash: "h", now: 101}});
  expect(registered.status).toBe(200);
  const id = registered.body.device.deviceRecordId;
  expect((await request("/legacy-reopen")).status).toBe(200);
  expect((await request("/device", {deviceRecordId: id})).body).toEqual(registered.body.device);
  expect((await request("/upgrade-schema", {version: 7})).status).toBe(200);
  const legacy = await request("/legacy-reopen");
  expect(legacy.status).toBe(500);
  expect(legacy.body.code).toBe("iroh_v2_unsupported_schema_history");
  expect((await request("/bridge-reopen")).status).toBe(200);
  expect((await request("/schema")).body.at(-1).version).toBe(7);
  expect((await request("/device", {deviceRecordId: id})).body).toEqual(registered.body.device);
  expect((await request("/revoke", {deviceRecordId: id, now: 102, actorUserId: identity.userId})).status).toBe(200);
  expect((await request("/device", {deviceRecordId: id})).body.revoked).toBe(true);
});
