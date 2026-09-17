import { expect, test, afterAll, beforeAll } from "bun:test";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { join } from "node:path";

let mf: Miniflare;
let stub: DurableObjectStub;
let migrationNamespace: DurableObjectNamespace;
let workerRoot = "";
let persistencePath = "";

const identity = { environment: "test", projectId: "iroh-v2-test", teamId: "team-e2e", userId: "u1", deviceId: "d1", appNamespace: "cmux", buildTag: "test" };
const descriptor = { identity, endpointId: "a".repeat(64), identityGeneration: 0, metadata: { platform: "mac", displayName: "Mac", appVersion: "1", pairingEnabled: true, capabilities: [], relayURLs: [] } };
const post = async (path: string, body: unknown) => {
  const response = await stub.fetch(`https://storage.test${path}`, { method: "POST", body: JSON.stringify(body) });
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
  const namespace = await mf.getDurableObjectNamespace("STORAGE");
  stub = namespace.getByName("team-e2e");
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
  expect((await post("/register", { input: { descriptor, challengeId: "c2", nonceHash: "n2", payloadHash: "p2", requestId: "r1", requestHash: "h1", now: 2002 } })).status).toBe(500);
  expect((await post("/revision", {})).body.revision).toBe(2);
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
  for (const mode of ["gap", "future", "wrong-hash"]) {
    expect((await migrationPost(`history-${mode}`, "/seed")).status).toBe(200);
    expect((await migrationPost(`history-${mode}`, "/corrupt", { mode })).status).toBe(200);
    const rejected = await migrationPost(`history-${mode}`, "/migrate");
    expect(rejected.status).toBe(500);
    expect(rejected.body.code).toMatch(/iroh_v2_(unsupported_schema_history|schema_migration_hash_mismatch)/);
  }
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
  expect(first.body.revision).toBe(5);
  expect((await post("/authority/get", { userId: "authority-user" })).body.expiresAt).toBe(4600);
  expect((await post("/authority/observe", { userId: "authority-user", verifiedAt: 900, expiresAt: 4500, now: 1000 })).body.revision).toBeNull();
  expect((await post("/authority/observe", { userId: "authority-user", verifiedAt: 2000, expiresAt: 5600, now: 2000 })).body.revision).toBe(6);
  expect((await post("/authority/observe", { userId: "authority-user", verifiedAt: 3000, expiresAt: 6601, now: 3000 })).status).toBe(500);
  expect((await post("/authority/observe", { userId: "authority-user", verifiedAt: 3000, expiresAt: 6600, now: 6600 })).status).toBe(500);
});

test("SQLite state survives a workerd restart", async () => {
  await mf.dispose();
  mf = new Miniflare({ ...convertV4MiniflareOptions({ rootPath: workerRoot, resourcePersistencePath: persistencePath, scriptPath: "worker.js", modules: true, durableObjects: { STORAGE: { className: "StorageTestDO", useSQLite: true }, MIGRATION: { className: "MigrationProbeDO", useSQLite: true } }, compatibilityDate: "2025-01-01" }), verbose: true });
  const namespace = await mf.getDurableObjectNamespace("STORAGE");
  stub = namespace.getByName("team-e2e");
  expect((await post("/revision", {})).body.revision).toBe(6);
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
  expect((await output(user, "a3", 1, 1, 1)).status).toBe(500);
  expect((await output(user, "a1", 3, 1, 1)).status).toBe(500);
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
  expect((await reserve(fullUser, "team-cap", "overflow", deviceKey("f"))).status).toBe(500);
});

test("socket reservations survive a second workerd restart", async () => {
  await mf.dispose();
  mf = new Miniflare({ ...convertV4MiniflareOptions({ rootPath: workerRoot, resourcePersistencePath: persistencePath, scriptPath: "worker.js", modules: true, durableObjects: { STORAGE: { className: "StorageTestDO", useSQLite: true }, MIGRATION: { className: "MigrationProbeDO", useSQLite: true } }, compatibilityDate: "2025-01-01" }), verbose: true });
  const namespace = await mf.getDurableObjectNamespace("STORAGE");
  stub = namespace.getByName("team-e2e");
  expect((await post("/socket/list", { userId: "socket-capacity" })).body.length).toBe(501);
});
