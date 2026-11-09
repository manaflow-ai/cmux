/**
 * Enroll intents (migration 0018). A caller keys an enroll by its own intentId; a revoke by that intent writes a
 * tombstone and deletes the device it made. The tombstone and the device insert meet on one row, so a create that
 * commits after the revoke (its provider call can take minutes) refuses with 409 mesh.device.intent_revoked and
 * deletes the tunnel it made: an empty device list after a revoke is final, whatever the timing.
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

it("refuses a create that commits after the revoke and deletes the tunnel it already made", async () => {
  const { admin, mesh } = await setup();
  const release = h.mesh.holdTunnelCreates();
  const pending = enroll(admin, mesh, "slow-intent");
  await h.mesh.tunnelCreateHeld();
  expect(liveTunnels()).toBe(1);

  // The create is between its claim and its commit: the tombstone is written, and the answer says to retry.
  expect((await revoke(admin, mesh, "slow-intent")).status).toBe(503);
  release();

  const late = await pending;
  expect(late.status).toBe(409);
  expect(await codeOf(late)).toBe("mesh.device.intent_revoked");
  expect(liveTunnels()).toBe(0);
  expect(await listed(admin, mesh)).toEqual([]);
  expect(h.mesh.store.devices).toHaveLength(0);
  expect(h.resources.filter((row) => row.kind === "device" || row.kind === "tunnel").every((row) => h.isDeleted(row.cmuxId))).toBe(true);
  // Now the revoke's answer is final, and the tombstone holds.
  expect(Schema.decodeUnknownSync(Revocation)(await (await revoke(admin, mesh, "slow-intent")).json())).toEqual({ deleted: false });
  expect(await codeOf(await enroll(admin, mesh, "slow-intent"))).toBe("mesh.device.intent_revoked");
});

it("keeps a late create's tunnel for the revoke to delete when the provider refuses its delete", async () => {
  const { admin, mesh } = await setup();
  const release = h.mesh.holdTunnelCreates();
  const pending = enroll(admin, mesh, "flaky-intent");
  await h.mesh.tunnelCreateHeld();
  expect((await revoke(admin, mesh, "flaky-intent")).status).toBe(503);
  h.mesh.failTunnelDeletes(500);
  release();
  expect(await codeOf(await pending)).toBe("mesh.device.intent_revoked");
  // The tunnel is still up, and its ownership rows stay live so a revoke can delete it.
  expect(liveTunnels()).toBe(1);
  expect(h.resources.filter((row) => row.kind === "device" || row.kind === "tunnel").some((row) => !h.isDeleted(row.cmuxId))).toBe(true);
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

it("refuses a malformed intentId", async () => {
  const { admin, mesh } = await setup();
  expect((await enroll(admin, mesh, "has space")).status).toBe(400);
  expect((await revoke(admin, mesh, "x".repeat(129))).status).toBe(404);
});
