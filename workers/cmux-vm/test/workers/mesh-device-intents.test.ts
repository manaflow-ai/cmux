/**
 * Enroll intents (migration 0018). A caller keys an enroll by its own intentId; a revoke by that intent writes a
 * tombstone and deletes the device it made. The tombstone and the device insert meet on one row, so a create that
 * commits after the revoke (its provider call can take minutes) refuses with 409 mesh.device.intent_revoked and
 * deletes the tunnel it made. Each create attempt keeps its own row until its tunnel is confirmed gone (found at the
 * provider by its slug when a reply was lost), and the revoke's 200 waits for every one of them.
 */
import { Schema } from "effect";
import { afterEach, beforeEach, expect, it } from "vitest";
import { ALL_SCOPES, bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { enrollBody, makeInstallKey, type InstallKey } from "../support/mesh-signing.ts";

const A = "team_alpha";
const KEY_1 = btoa("a".repeat(32));
const KEY_2 = btoa("b".repeat(32));
const Enrolled = Schema.Struct({ device: Schema.Struct({ id: Schema.String, tunnelId: Schema.String }) });
const Revocation = Schema.Struct({ deleted: Schema.Boolean });
const ConflictBody = Schema.Struct({ code: Schema.optional(Schema.String) });
const MeshBody = Schema.Struct({ id: Schema.String });
const DeviceListBody = Schema.Struct({ items: Schema.Array(Schema.Struct({ id: Schema.String })) });

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness;
let install: InstallKey;
beforeEach(async () => {
  h = await makeHarness();
  install = await makeInstallKey();
});
afterEach(async () => { await h.dispose(); });

const setup = async () => {
  const admin = await h.addKey(A, ALL_SCOPES);
  const created = await h.request("/v1/meshes", bearer(admin), { method: "POST", body: {} });
  expect(created.status).toBe(201);
  return { admin, mesh: Schema.decodeUnknownSync(MeshBody)(await created.json()).id };
};
const enroll = async (key: string, mesh: string, intentId: string, wgPublicKey = KEY_1) =>
  h.request(`/v1/meshes/${mesh}/devices`, bearer(key), { method: "POST", body: { ...(await enrollBody(install, mesh, { name: "mac", wgPublicKey })), intentId } });
const revoke = (key: string, mesh: string, intentId: string) => h.request(`/v1/meshes/${mesh}/device-intents/${intentId}/revoke`, bearer(key), { method: "POST" });
const listed = async (key: string, mesh: string) => Schema.decodeUnknownSync(DeviceListBody)(await (await h.request(`/v1/meshes/${mesh}/devices`, bearer(key))).json()).items;
const liveTunnels = () => h.mesh.tunnels.size;
const codeOf = async (response: Response) => Schema.decodeUnknownSync(ConflictBody)(await response.json()).code;

it("deletes the device (and its tunnel) an intent made, and is idempotent", async () => {
  const { admin, mesh } = await setup();
  const made = await enroll(admin, mesh, "intent-1");
  expect(made.status).toBe(201);
  const { device } = Schema.decodeUnknownSync(Enrolled)(await made.json());
  expect(liveTunnels()).toBe(1);

  const first = await revoke(admin, mesh, "intent-1");
  expect(first.status).toBe(200);
  expect(Schema.decodeUnknownSync(Revocation)(await first.json())).toEqual({ deleted: true });
  expect(liveTunnels()).toBe(0);
  expect((await h.request(`/v1/devices/${device.id}`, bearer(admin))).status).toBe(404);
  expect(await listed(admin, mesh)).toEqual([]);

  const again = await revoke(admin, mesh, "intent-1");
  expect(again.status).toBe(200);
  expect(Schema.decodeUnknownSync(Revocation)(await again.json())).toEqual({ deleted: false });
});

it("refuses an enroll after its intent was revoked, creating nothing", async () => {
  const { admin, mesh } = await setup();
  expect(Schema.decodeUnknownSync(Revocation)(await (await revoke(admin, mesh, "never-used")).json())).toEqual({ deleted: false });
  const late = await enroll(admin, mesh, "never-used");
  expect(late.status).toBe(409);
  expect(await codeOf(late)).toBe("mesh.device.intent_revoked");
  expect(h.upstream.callsTo("POST", /^\/v5\/tunnels$/u)).toHaveLength(0);
  expect(await listed(admin, mesh)).toEqual([]);
});

it("finds a late create's tunnel by its slug while the reply is held, deletes it, and the late commit refuses", async () => {
  const { admin, mesh } = await setup();
  const release = h.mesh.holdTunnelCreates();
  const pending = enroll(admin, mesh, "slow-intent");
  await h.mesh.tunnelCreateHeld();
  expect(liveTunnels()).toBe(1);

  // The provider made the tunnel but its reply has not reached the create: the revoke finds it at the provider and
  // deletes it, so its 200 is true and final.
  const revoked = await revoke(admin, mesh, "slow-intent");
  expect(revoked.status).toBe(200);
  expect(Schema.decodeUnknownSync(Revocation)(await revoked.json())).toEqual({ deleted: true });
  expect(liveTunnels()).toBe(0);
  release();

  const late = await pending;
  expect(late.status).toBe(409);
  expect(await codeOf(late)).toBe("mesh.device.intent_revoked");
  expect(liveTunnels()).toBe(0);
  expect(await listed(admin, mesh)).toEqual([]);
  expect(h.mesh.store.devices.filter((row) => row.deletedAt === null)).toHaveLength(0);
  expect(h.resources.filter((row) => row.kind === "device" || row.kind === "tunnel").every((row) => h.isDeleted(row.cmuxId))).toBe(true);
  expect(Schema.decodeUnknownSync(Revocation)(await (await revoke(admin, mesh, "slow-intent")).json())).toEqual({ deleted: false });
  expect(await codeOf(await enroll(admin, mesh, "slow-intent"))).toBe("mesh.device.intent_revoked");
});

it("answers 503, never a final 200, while a sent create has not landed, also past the 10-minute claim window", async () => {
  const { admin, mesh } = await setup();
  const release = h.mesh.holdTunnelLanding();
  const pending = enroll(admin, mesh, "held-intent");
  await h.mesh.tunnelCreateHeld();
  expect(liveTunnels()).toBe(0);
  expect((await revoke(admin, mesh, "held-intent")).status).toBe(503);
  // The claim and its send are 11 minutes old: age alone proves nothing, so the answer is still 503.
  for (const attempt of h.mesh.store.deviceIntentAttempts()) {
    attempt.createdAt = new Date(attempt.createdAt.getTime() - 11 * 60_000);
    if (attempt.sentAt !== null) attempt.sentAt = new Date(attempt.sentAt.getTime() - 11 * 60_000);
  }
  expect((await revoke(admin, mesh, "held-intent")).status).toBe(503);
  release();
  // The create lands late, refuses at its commit and deletes its tunnel; only then is the revoke's 200 final.
  expect(await codeOf(await pending)).toBe("mesh.device.intent_revoked");
  expect(liveTunnels()).toBe(0);
  expect(Schema.decodeUnknownSync(Revocation)(await (await revoke(admin, mesh, "held-intent")).json())).toEqual({ deleted: false });
});

it("keeps a late create's tunnel for the revoke to delete when the provider refuses its delete", async () => {
  const { admin, mesh } = await setup();
  const release = h.mesh.holdTunnelCreates();
  const pending = enroll(admin, mesh, "flaky-intent");
  await h.mesh.tunnelCreateHeld();
  h.mesh.failTunnelDeletes(500);
  // The revoke finds the tunnel but cannot delete it: 503.
  expect((await revoke(admin, mesh, "flaky-intent")).status).toBe(503);
  release();
  expect(await codeOf(await pending)).toBe("mesh.device.intent_revoked");
  // The tunnel is still up, its ownership rows stay live, and its attempt stays open.
  expect(liveTunnels()).toBe(1);
  expect(h.resources.filter((row) => row.kind === "device" || row.kind === "tunnel").some((row) => !h.isDeleted(row.cmuxId))).toBe(true);
  expect(h.mesh.store.deviceIntentAttempts().filter((attempt) => attempt.resolvedAt === null)).toHaveLength(1);
  expect(await listed(admin, mesh)).toEqual([]);
  // Every revoke retries the delete and answers 503 until it works, never a final 200 with the tunnel up.
  expect((await revoke(admin, mesh, "flaky-intent")).status).toBe(503);
  expect(liveTunnels()).toBe(1);
  h.mesh.failTunnelDeletes(null);
  const cleaned = await revoke(admin, mesh, "flaky-intent");
  expect(cleaned.status).toBe(200);
  expect(Schema.decodeUnknownSync(Revocation)(await cleaned.json())).toEqual({ deleted: true });
  expect(liveTunnels()).toBe(0);
  expect(h.resources.filter((row) => row.kind === "device" || row.kind === "tunnel").every((row) => h.isDeleted(row.cmuxId))).toBe(true);
  expect(Schema.decodeUnknownSync(Revocation)(await (await revoke(admin, mesh, "flaky-intent")).json())).toEqual({ deleted: false });
});

it("finds and deletes the tunnel of a create whose reply was lost, instead of calling it absent", async () => {
  const { admin, mesh } = await setup();
  h.mesh.loseTunnelReplies(1);
  // The provider made the tunnel; the Worker saw a 504. The attempt stays open and the claim stays held.
  expect((await enroll(admin, mesh, "lost-intent")).status).toBe(503);
  expect(liveTunnels()).toBe(1);
  expect(h.mesh.store.deviceIntentAttempts().filter((attempt) => attempt.resolvedAt === null)).toHaveLength(1);
  expect(h.mesh.store.deviceIntents().find((row) => row.intentId === "lost-intent")?.deviceId).not.toBeNull();
  const revoked = await revoke(admin, mesh, "lost-intent");
  expect(revoked.status).toBe(200);
  expect(Schema.decodeUnknownSync(Revocation)(await revoked.json())).toEqual({ deleted: true });
  expect(liveTunnels()).toBe(0);
  expect(Schema.decodeUnknownSync(Revocation)(await (await revoke(admin, mesh, "lost-intent")).json())).toEqual({ deleted: false });

  // A retry of a lost create deletes the tunnel the first try made before it creates its own.
  h.mesh.loseTunnelReplies(1);
  expect((await enroll(admin, mesh, "lost-retry")).status).toBe(503);
  expect(liveTunnels()).toBe(1);
  expect((await enroll(admin, mesh, "lost-retry")).status).toBe(201);
  expect(liveTunnels()).toBe(1);
  expect(await listed(admin, mesh)).toHaveLength(1);
});

it("keeps the claim of a create whose rollback failed, and a takeover keeps that attempt's cleanup tracked", async () => {
  const { admin, mesh } = await setup();
  h.mesh.failIntentCommits(1);
  h.mesh.failTunnelDeletes(500);
  // The commit fails after the tunnel exists, and so does its delete: the claim and the attempt stay.
  expect((await enroll(admin, mesh, "rollback-intent")).status).toBe(503);
  expect(liveTunnels()).toBe(1);
  const first = h.mesh.store.deviceIntentAttempts().find((attempt) => attempt.intentId === "rollback-intent");
  expect(first?.resolvedAt).toBeNull();
  expect(h.mesh.store.deviceIntents().find((row) => row.intentId === "rollback-intent")?.deviceId).toBe(first?.deviceId);
  // A retry takes the claim over but must delete the first attempt's tunnel first: while that fails it refuses, and the
  // first attempt stays recorded and open.
  expect((await enroll(admin, mesh, "rollback-intent")).status).toBe(503);
  expect(h.mesh.store.deviceIntentAttempts().find((attempt) => attempt.deviceId === first?.deviceId)?.resolvedAt).toBeNull();
  expect(liveTunnels()).toBe(1);
  h.mesh.failTunnelDeletes(null);
  const retried = await enroll(admin, mesh, "rollback-intent");
  expect(retried.status).toBe(201);
  expect(h.mesh.store.deviceIntentAttempts().find((attempt) => attempt.deviceId === first?.deviceId)?.resolvedAt).not.toBeNull();
  expect(liveTunnels()).toBe(1);
  // The revoke deletes the device the retry made; nothing of either attempt is left.
  expect(Schema.decodeUnknownSync(Revocation)(await (await revoke(admin, mesh, "rollback-intent")).json())).toEqual({ deleted: true });
  expect(liveTunnels()).toBe(0);
});

it("never lets one member tombstone an intent another member claimed after it looked", async () => {
  const { mesh } = await setup();
  const a = await h.addKey(A, ["mesh:read", "mesh:join"]);
  const b = await h.addKey(A, ["mesh:read", "mesh:join"]);
  // A finds the intent unused; B claims it (its create is in flight); then A's revoke lands.
  expect(h.mesh.store.deviceIntents().find((row) => row.intentId === "shared")).toBeUndefined();
  const release = h.mesh.holdTunnelCreates();
  const pending = enroll(b, mesh, "shared");
  await h.mesh.tunnelCreateHeld();
  expect((await revoke(a, mesh, "shared")).status).toBe(404);
  expect(h.mesh.store.deviceIntents().find((row) => row.intentId === "shared")?.revokedAt).toBeNull();
  release();
  expect((await pending).status).toBe(201);
  expect(liveTunnels()).toBe(1);
  // The other order is the intended one: an intent A tombstoned first is refused to B.
  expect(Schema.decodeUnknownSync(Revocation)(await (await revoke(a, mesh, "first-a")).json())).toEqual({ deleted: false });
  expect(await codeOf(await enroll(b, mesh, "first-a", KEY_2))).toBe("mesh.device.intent_revoked");
});

it("refuses a revoke by an admin confined to other resources, in flight too, and writes nothing", async () => {
  const { mesh } = await setup();
  const member = await h.addKey(A, ["mesh:read", "mesh:join"]);
  // An admin key limited to this mesh id: it reaches the mesh, but not the device another principal's create makes.
  const confined = await h.addKey(A, ALL_SCOPES, { allowlist: [mesh] });
  const release = h.mesh.holdTunnelLanding();
  const pending = enroll(member, mesh, "confined-intent");
  await h.mesh.tunnelCreateHeld();
  // 404 before any 503: the authorization is decided in the tombstone's own write.
  expect((await revoke(confined, mesh, "confined-intent")).status).toBe(404);
  expect(h.mesh.store.deviceIntents().find((row) => row.intentId === "confined-intent")?.revokedAt).toBeNull();
  release();
  expect((await pending).status).toBe(201);
  expect((await revoke(confined, mesh, "confined-intent")).status).toBe(404);
  expect(h.mesh.store.deviceIntents().find((row) => row.intentId === "confined-intent")?.revokedAt).toBeNull();
  expect(liveTunnels()).toBe(1);
});

it("answers the same device for a repeat with the same intentId, and 409 for other keys", async () => {
  const { admin, mesh } = await setup();
  const first = await enroll(admin, mesh, "intent-r");
  expect(first.status).toBe(201);
  const original = Schema.decodeUnknownSync(Enrolled)(await first.json());
  const repeat = await enroll(admin, mesh, "intent-r");
  expect(repeat.status).toBe(201);
  expect(Schema.decodeUnknownSync(Enrolled)(await repeat.json()).device).toEqual(original.device);
  expect(h.upstream.callsTo("POST", /^\/v5\/tunnels$/u)).toHaveLength(1);
  expect((await enroll(admin, mesh, "intent-r", KEY_2)).status).toBe(409);
  // Without an intent, a second enroll of the same key is the old 409.
  const plain = await h.request(`/v1/meshes/${mesh}/devices`, bearer(admin), { method: "POST", body: await enrollBody(install, mesh, { name: "mac", wgPublicKey: KEY_1 }) });
  expect(plain.status).toBe(409);
});

it("revokes the intent of a device deleted directly, so its late repeat refuses", async () => {
  const { admin, mesh } = await setup();
  const { device } = Schema.decodeUnknownSync(Enrolled)(await (await enroll(admin, mesh, "intent-d")).json());
  expect((await h.request(`/v1/devices/${device.id}`, bearer(admin), { method: "DELETE" })).status).toBe(204);
  expect(await codeOf(await enroll(admin, mesh, "intent-d"))).toBe("mesh.device.intent_revoked");
});

it("applies the device delete rules to a revoke: another member and other labels get 404 and write nothing", async () => {
  const { admin, mesh } = await setup();
  const member = await h.addKey(A, ["mesh:read", "mesh:join"]);
  expect((await enroll(member, mesh, "member-intent")).status).toBe(201);
  const other = await h.addKey(A, ["mesh:read", "mesh:join"]);
  expect((await revoke(other, mesh, "member-intent")).status).toBe(404);
  // An admin confined to labels the mesh and device do not carry cannot reach them either.
  const confined = await h.addKey(A, ALL_SCOPES, { agentLabels: { role: "other" } });
  expect((await revoke(confined, mesh, "member-intent")).status).toBe(404);
  expect(h.mesh.store.deviceIntents().find((row) => row.intentId === "member-intent")?.revokedAt).toBeNull();
  expect(liveTunnels()).toBe(1);
  // The tenant admin may revoke it.
  expect(Schema.decodeUnknownSync(Revocation)(await (await revoke(admin, mesh, "member-intent")).json())).toEqual({ deleted: true });
  expect(liveTunnels()).toBe(0);
  // Another tenant's key sees no mesh at all.
  expect((await revoke(await h.addKey("team_bravo", ALL_SCOPES), mesh, "member-intent")).status).toBe(404);
});

it("takes the replay path when the original create commits while a retry is between its reads", async () => {
  const { admin, mesh } = await setup();
  const release = h.mesh.holdTunnelCreates();
  const original = enroll(admin, mesh, "race-intent");
  await h.mesh.tunnelCreateHeld();
  // The retry reads the claim as live and stalls right after reading the intent's attempts.
  const pause = h.mesh.holdNextOpenAttemptsRead();
  const retry = enroll(admin, mesh, "race-intent");
  await pause.reached;
  release();
  const first = await original;
  expect(first.status).toBe(201);
  const made = Schema.decodeUnknownSync(Enrolled)(await first.json());
  pause.release();
  // The committed intent is never reconciled: the retry answers the same device, and nothing is deleted.
  const second = await retry;
  expect(second.status).toBe(201);
  expect(Schema.decodeUnknownSync(Enrolled)(await second.json()).device).toEqual(made.device);
  expect(liveTunnels()).toBe(1);
  expect(await listed(admin, mesh)).toEqual([{ id: made.device.id }]);
});

it("never lets an enroll with another principal's intent settle it or delete its tunnel", async () => {
  const { mesh } = await setup();
  const owner = await h.addKey(A, ["mesh:read", "mesh:join"]);
  const other = await h.addKey(A, ["mesh:read", "mesh:join"]);
  h.mesh.loseTunnelReplies(1);
  // The owner's create made a tunnel and lost the reply: its claim and attempt stay open.
  expect((await enroll(owner, mesh, "owned-intent")).status).toBe(503);
  expect(liveTunnels()).toBe(1);
  const before = h.mesh.store.deviceIntents().find((row) => row.intentId === "owned-intent");
  // Another member (whose revoke would be 404) enrolls with it: 404, and the tunnel, claim and attempt stay as they were.
  expect((await enroll(other, mesh, "owned-intent", KEY_2)).status).toBe(404);
  expect(liveTunnels()).toBe(1);
  expect(h.mesh.store.deviceIntents().find((row) => row.intentId === "owned-intent")?.deviceId).toBe(before?.deviceId);
  expect(h.mesh.store.deviceIntentAttempts().filter((attempt) => attempt.intentId === "owned-intent" && attempt.resolvedAt === null)).toHaveLength(1);
  expect((await revoke(other, mesh, "owned-intent")).status).toBe(404);
  // A forged signature settles nothing either: it is refused before any intent is touched.
  const forged = await h.request(`/v1/meshes/${mesh}/devices`, bearer(owner), {
    method: "POST",
    body: { ...(await enrollBody(install, mesh, { name: "mac", wgPublicKey: KEY_1 })), signature: btoa("x".repeat(64)), intentId: "owned-intent" },
  });
  expect(forged.status).toBe(403);
  expect(liveTunnels()).toBe(1);
  // Its owner's retry deletes the tunnel the lost create made, then enrolls.
  expect((await enroll(owner, mesh, "owned-intent")).status).toBe(201);
  expect(liveTunnels()).toBe(1);
  // And with a committed intent, another member gets 404 as well.
  expect((await enroll(other, mesh, "owned-intent", KEY_2)).status).toBe(404);
});

it("calls a create the provider answered with an error settled at once", async () => {
  const { admin, mesh } = await setup();
  h.mesh.failTunnelCreates(500);
  expect((await enroll(admin, mesh, "answered-intent")).status).toBe(503);
  h.mesh.failTunnelCreates(null);
  // The provider answered (no tunnel at the slug): the revoke's 200 is final at once, not after the send grace.
  const revoked = await revoke(admin, mesh, "answered-intent");
  expect(revoked.status).toBe(200);
  expect(Schema.decodeUnknownSync(Revocation)(await revoked.json())).toEqual({ deleted: false });
});

it("revokes a deleted device's intent before hiding the device, so a failed revocation is retried by DELETE", async () => {
  const { admin, mesh } = await setup();
  const { device } = Schema.decodeUnknownSync(Enrolled)(await (await enroll(admin, mesh, "delete-intent")).json());
  h.mesh.failIntentOfDeviceRevokes(1);
  expect((await h.request(`/v1/devices/${device.id}`, bearer(admin), { method: "DELETE" })).status).toBe(503);
  // Nothing was hidden: the device and its tunnel are still reachable, so the retry finishes the job.
  expect((await h.request(`/v1/devices/${device.id}`, bearer(admin))).status).toBe(200);
  expect(liveTunnels()).toBe(1);
  expect((await h.request(`/v1/devices/${device.id}`, bearer(admin), { method: "DELETE" })).status).toBe(204);
  expect(liveTunnels()).toBe(0);
  expect(await codeOf(await enroll(admin, mesh, "delete-intent"))).toBe("mesh.device.intent_revoked");
});

it("accepts the platform's resend of the same signed body and intent after the provider answered a 500, and nowhere else", async () => {
  const { admin, mesh } = await setup();
  // The platform stores the device's signed body once and resends it unchanged: same signedAt, nonce and signature.
  const signed = await enrollBody(install, mesh, { name: "mac", wgPublicKey: KEY_1 });
  const send = (intentId: string) => h.request(`/v1/meshes/${mesh}/devices`, bearer(admin), { method: "POST", body: { ...signed, intentId } });
  h.mesh.failTunnelCreates(500);
  expect((await send("platform-intent")).status).toBe(503);
  h.mesh.failTunnelCreates(null);
  // The same nonce under another intent stays a replay, and creates nothing.
  const creates = h.upstream.callsTo("POST", /^\/v5\/tunnels$/u).length;
  expect((await send("other-intent")).status).toBe(409);
  expect(h.upstream.callsTo("POST", /^\/v5\/tunnels$/u)).toHaveLength(creates);
  expect(h.mesh.store.deviceIntents().find((row) => row.intentId === "other-intent")).toBeUndefined();
  // And without an intent.
  expect((await h.request(`/v1/meshes/${mesh}/devices`, bearer(admin), { method: "POST", body: signed })).status).toBe(409);
  // The resend with the same intent settles the answered attempt and enrolls.
  const retried = await send("platform-intent");
  expect(retried.status).toBe(201);
  expect(liveTunnels()).toBe(1);
  // A further resend answers the committed device.
  const again = await send("platform-intent");
  expect(again.status).toBe(201);
  expect(Schema.decodeUnknownSync(Enrolled)(await again.json()).device).toEqual(Schema.decodeUnknownSync(Enrolled)(await retried.json()).device);
});

it("never lets a paused reconcile touch the attempt a later retry claimed and committed", async () => {
  const { admin, mesh } = await setup();
  const owner = await h.addKey(A, ["mesh:read", "mesh:join"]);
  h.mesh.loseTunnelReplies(1);
  // The owner's first create made a tunnel and lost its reply: one open attempt, its claim held.
  expect((await enroll(owner, mesh, "fenced-intent")).status).toBe(503);
  expect(liveTunnels()).toBe(1);
  // Retry A ends that claim (fencing the open attempt) and pauses right after.
  const pause = h.mesh.holdNextReconcile();
  const retryA = enroll(owner, mesh, "fenced-intent");
  await pause.reached;
  // Admin retry B settles the old attempt, claims the intent and commits its own device.
  const retryB = await enroll(admin, mesh, "fenced-intent", KEY_2);
  expect(retryB.status).toBe(201);
  const made = Schema.decodeUnknownSync(Enrolled)(await retryB.json());
  expect(liveTunnels()).toBe(1);
  // A resumes: it may act only on the attempt it fenced, which B already settled. B's device and tunnel survive.
  pause.release();
  expect((await retryA).status).toBe(409);
  expect(liveTunnels()).toBe(1);
  expect(await listed(admin, mesh)).toEqual([{ id: made.device.id }]);
  expect((await h.request(`/v1/devices/${made.device.id}`, bearer(admin))).status).toBe(200);
  expect(h.isDeleted(made.device.id)).toBe(false);
});

it("refuses a malformed intentId", async () => {
  const { admin, mesh } = await setup();
  expect((await enroll(admin, mesh, "has space")).status).toBe(400);
  expect((await revoke(admin, mesh, "x".repeat(129))).status).toBe(404);
});
