/**
 * Enroll intents (migration 0018) against the real migration on an in-process Postgres (PGlite): the claim and its
 * attempt row, the send fence, the commit that is the device insert, the tombstone and its authorization, the release,
 * and the expiry.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer, Option } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import s2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import snapshots from "../../migrations/0003_cmux_vm_snapshot_parent.sql?raw";
import mesh from "../../migrations/0004_cmux_vm_mesh.sql?raw";
import meshM2 from "../../migrations/0005_cmux_vm_mesh_m2.sql?raw";
import meshM3 from "../../migrations/0006_cmux_vm_mesh_m3.sql?raw";
import deviceIntents from "../../migrations/0018_cmux_vm_mesh_device_intents.sql?raw";
import { INTENT_STALE_CLAIM_MS, INTENT_TOMBSTONE_MS, RECONCILE_LEASE_MS, absenceIsFinal, intentState, sqlDeviceIntents, type DeviceIntentStore } from "../../src/db/mesh-intents.ts";
import { MeshStore, sqlMeshStoreLayer, type MeshDeviceRow } from "../../src/db/mesh.ts";
import { sweepableTunnelDevices } from "../../src/db/orphans.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { newDeviceId, newMeshId, newTunnelId, TenantId } from "../../src/lib/ids.ts";

const A = TenantId.make("team_alpha");
const at = new Date(Date.UTC(2026, 10, 9, 0, 0));
const later = (ms: number) => new Date(at.getTime() + ms);
let pg: PGlite;
let store: DeviceIntentStore;
const run = <A>(effect: Effect.Effect<A, StoreError>) => Effect.runPromise(effect);
const owner: Parameters<DeviceIntentStore["revokeDeviceIntent"]>[3] = { ref: "key:x", labels: {}, admin: false, allowlist: null };
const revokeAs = async (meshId: string, intentId: string, when: Date, caller = owner) => {
  const row = await run(store.revokeDeviceIntent(A, meshId, intentId, caller, when));
  if (Option.isNone(row)) throw new Error("revoke refused");
  return row.value;
};

beforeEach(async () => {
  pg = new PGlite();
  for (const migration of [ownership, s2, snapshots, mesh, meshM2, meshM3, deviceIntents]) await pg.exec(migration);
  store = sqlDeviceIntents({
    query: (operation, text, params) =>
      Effect.tryPromise({ try: async () => (await pg.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
  });
});

const deviceRow = (meshId: string, deviceId: string): MeshDeviceRow => ({
  deviceId,
  meshId,
  tunnelId: newTunnelId(),
  name: "mac",
  wgPublicKey: btoa("a".repeat(32)),
  installPublicKey: null,
  createdBy: "key:x",
  createdAt: at,
});
const devicesOf = async () => (await pg.query("SELECT device_cmux_id FROM cmux_vm.mesh_devices")).rows;
const claim = (meshId: string, intentId: string, deviceId: string, when: Date, by = "key:x", labels: Record<string, string> = {}, admin = false) =>
  run(store.claimDeviceIntent(A, meshId, intentId, { deviceId, tunnelId: newTunnelId() }, { ref: by, labels, admin, allowlist: null }, when));
const keyOf = (meshId: string, intentId: string, deviceId: string) => ({ tenantId: A, meshId, intentId, deviceId });
const openOf = async (meshId: string, intentId: string) => (await run(store.listOpenAttempts(A, meshId, intentId))).map((attempt) => attempt.deviceId);

describe("mesh device intents", () => {
  it("commits the device row only for the live claim, and a tombstone before the commit inserts nothing", async () => {
    const meshId = newMeshId();
    const first = newDeviceId();
    expect(await claim(meshId, "i-1", first, at)).toBe(true);
    // A second claim while the first is live is refused, whatever its age: a claim's age never frees it.
    expect(await claim(meshId, "i-1", newDeviceId(), later(1))).toBe(false);
    expect(await claim(meshId, "i-1", newDeviceId(), later(INTENT_TOMBSTONE_MS))).toBe(false);
    const revoked = await revokeAs(meshId, "i-1", later(2));
    expect(revoked).toMatchObject({ deviceId: first, committedAt: null, attemptDeviceIds: [first] });
    expect(revoked.revokedAt).not.toBeNull();
    expect(await run(store.commitDeviceIntent(A, "i-1", deviceRow(meshId, first), later(3)))).toBe(false);
    expect(await devicesOf()).toEqual([]);
    expect(intentState(await run(store.findDeviceIntent(A, meshId, "i-1")), later(4))).toBe("revoked");
    // Idempotent: a second revoke keeps the first tombstone's time.
    expect((await revokeAs(meshId, "i-1", later(5))).revokedAt).toEqual(revoked.revokedAt);
  });

  it("lets a revoke after the commit see the committed device", async () => {
    const meshId = newMeshId();
    const device = newDeviceId();
    await claim(meshId, "i-2", device, at);
    expect(await run(store.commitDeviceIntent(A, "i-2", deviceRow(meshId, device), later(1)))).toBe(true);
    expect(await devicesOf()).toEqual([{ device_cmux_id: device }]);
    expect(intentState(await run(store.findDeviceIntent(A, meshId, "i-2")), later(2))).toBe("committed");
    expect(await run(store.commitDeviceIntent(A, "i-2", deviceRow(meshId, device), later(2)))).toBe(false);
    const revoked = await revokeAs(meshId, "i-2", later(3));
    expect(revoked.deviceId).toBe(device);
    expect(revoked.committedAt).not.toBeNull();
  });

  it("orders the send and its resolution on the attempt row: a resolved attempt never sends, a sent one is never resolved unseen", async () => {
    const meshId = newMeshId();
    const first = newDeviceId();
    await claim(meshId, "i-3", first, at);
    expect(await run(store.resolveUnsentAttempt(keyOf(meshId, "i-3", first), later(1)))).toBe(true);
    expect(await run(store.markAttemptSent(keyOf(meshId, "i-3", first), later(2)))).toBe(false);
    // The other order: once sent, the unsent resolution writes nothing.
    await run(store.releaseDeviceIntent(keyOf(meshId, "i-3", first)));
    const second = newDeviceId();
    expect(await claim(meshId, "i-3", second, later(3))).toBe(true);
    expect(await run(store.markAttemptSent(keyOf(meshId, "i-3", second), later(4)))).toBe(true);
    expect(await run(store.resolveUnsentAttempt(keyOf(meshId, "i-3", second), later(5)))).toBe(false);
    expect(await openOf(meshId, "i-3")).toEqual([second]);
    // A revoked intent's attempt cannot send.
    const third = newDeviceId();
    const meshB = newMeshId();
    await claim(meshB, "i-3", third, at);
    await revokeAs(meshB, "i-3", later(1));
    expect(await run(store.markAttemptSent(keyOf(meshB, "i-3", third), later(2)))).toBe(false);
  });

  it("keeps every attempt as its own row: a takeover never replaces an earlier attempt's record", async () => {
    const meshId = newMeshId();
    const first = newDeviceId();
    await claim(meshId, "i-4", first, at);
    await run(store.markAttemptSent(keyOf(meshId, "i-4", first), later(1)));
    await run(store.recordAttemptAnswer(keyOf(meshId, "i-4", first), "tun-upstream-1", later(2)));
    await run(store.finishAttempt(keyOf(meshId, "i-4", first), later(2)));
    // A reconcile ends its claim without resolving it (its tunnel delete failed): no new claim starts while it is open.
    // It returns, from its own statement, exactly the attempts open when it ended the claim.
    const ended = await run(store.beginReconcile(A, meshId, "i-4", owner, { token: "t-1", mode: "enroll" }, later(3)));
    expect(Option.map(ended, (value) => value.fenced.map((attempt) => [attempt.seq, attempt.deviceId, attempt.upstreamId, attempt.sentAt?.getTime()]))).toEqual(
      Option.some([[1, first, "tun-upstream-1", later(1).getTime()]]),
    );
    expect(Option.map(ended, (value) => value.intent.reconcileToken)).toEqual(Option.some("t-1"));
    expect(await run(store.commitDeviceIntent(A, "i-4", deviceRow(meshId, first), later(4)))).toBe(false);
    const second = newDeviceId();
    expect(await claim(meshId, "i-4", second, later(5))).toBe(false);
    const kept = await run(store.findAttempt(keyOf(meshId, "i-4", first)));
    expect(Option.map(kept, (attempt) => [attempt.upstreamId, attempt.resolvedAt])).toEqual(Option.some(["tun-upstream-1", null]));
    // Only the token holding the row may resolve it, and while its token is live no claim is taken.
    expect(await run(store.resolveFencedAttempt(keyOf(meshId, "i-4", first), "t-other", false, later(6)))).toBe(false);
    expect(await run(store.resolveFencedAttempt(keyOf(meshId, "i-4", first), "t-1", false, later(6)))).toBe(true);
    expect(await claim(meshId, "i-4", second, later(7))).toBe(false);
    await run(store.endReconcile(A, meshId, "i-4", "t-1"));
    // Once its tunnel is confirmed gone and the reconcile ended, the next claim adds its own row beside it.
    expect(await claim(meshId, "i-4", second, later(7))).toBe(true);
    expect(await openOf(meshId, "i-4")).toEqual([second]);
    expect(Option.map(await run(store.findAttempt(keyOf(meshId, "i-4", second))), (attempt) => attempt.seq)).toEqual(Option.some(2));
    expect((await revokeAs(meshId, "i-4", later(8))).attemptDeviceIds).toEqual([first, second]);
  });

  it("fences a reconcile: its writes need its token and seq <= fence, and a lapsed lease is taken over", async () => {
    const meshId = newMeshId();
    const first = newDeviceId();
    await claim(meshId, "i-14", first, at);
    await run(store.finishAttempt(keyOf(meshId, "i-14", first), later(1)));
    expect(Option.isSome(await run(store.beginReconcile(A, meshId, "i-14", owner, { token: "t-a", mode: "enroll" }, later(2))))).toBe(true);
    // A second reconcile waits while the lease runs.
    expect(Option.isNone(await run(store.beginReconcile(A, meshId, "i-14", owner, { token: "t-b", mode: "enroll" }, later(3))))).toBe(true);
    expect(await run(store.renewReconcile(A, meshId, "i-14", "t-a", later(RECONCILE_LEASE_MS)))).toBe(true);
    // The lease lapses: B takes the row over, resolves the attempt and claims a new one.
    const lapsed = later(2 * RECONCILE_LEASE_MS + 1);
    expect(Option.isSome(await run(store.beginReconcile(A, meshId, "i-14", owner, { token: "t-b", mode: "enroll" }, lapsed)))).toBe(true);
    expect(await run(store.renewReconcile(A, meshId, "i-14", "t-a", lapsed))).toBe(false);
    expect(await run(store.resolveFencedAttempt(keyOf(meshId, "i-14", first), "t-b", true, lapsed))).toBe(true);
    await run(store.endReconcile(A, meshId, "i-14", "t-a"));
    expect((await run(store.findDeviceIntent(A, meshId, "i-14"))).pipe(Option.map((row) => row.reconcileToken))).toEqual(Option.some("t-b"));
    await run(store.endReconcile(A, meshId, "i-14", "t-b"));
    const second = newDeviceId();
    expect(await claim(meshId, "i-14", second, lapsed)).toBe(true);
    // A's late write reaches nothing: not its token, and the new attempt is past any fence.
    expect(await run(store.resolveFencedAttempt(keyOf(meshId, "i-14", second), "t-a", false, lapsed))).toBe(false);
    expect(await openOf(meshId, "i-14")).toEqual([second]);
  });

  it("releases a deleted device's commit, so its intent can be claimed again after the tombstone", async () => {
    const meshId = newMeshId();
    const device = newDeviceId();
    await claim(meshId, "i-15", device, at);
    await run(store.commitDeviceIntent(A, "i-15", deviceRow(meshId, device), at));
    await run(store.revokeIntentOfDevice(A, device, later(1)));
    await run(store.releaseCommitOfDevice(A, device, later(2)));
    expect((await run(store.findDeviceIntent(A, meshId, "i-15"))).pipe(Option.map((row) => [row.committedAt, row.deviceId]))).toEqual(Option.some([null, null]));
    expect(await openOf(meshId, "i-15")).toEqual([]);
    expect(await claim(meshId, "i-15", newDeviceId(), later(INTENT_TOMBSTONE_MS))).toBe(false);
    expect(await claim(meshId, "i-15", newDeviceId(), later(INTENT_TOMBSTONE_MS + 2))).toBe(true);
  });

  it("never commits a resolved attempt, so a tunnel that lands after its resolution backs no device", async () => {
    const meshId = newMeshId();
    const device = newDeviceId();
    await claim(meshId, "i-16", device, at);
    expect(await run(store.markAttemptSent(keyOf(meshId, "i-16", device), at))).toBe(true);
    await run(store.resolveAttempt(keyOf(meshId, "i-16", device), later(1)));
    expect(await run(store.commitDeviceIntent(A, "i-16", deviceRow(meshId, device), later(2)))).toBe(false);
    expect(await devicesOf()).toEqual([]);
  });

  it("names for the tunnel sweep only devices with no live row whose attempt is resolved or whose intent is revoked", async () => {
    const meshId = newMeshId();
    const sweepable = async (owners: ReadonlyArray<{ tenantId: string; deviceId: string }>) =>
      [...(await Effect.runPromise(Effect.provide(sweepableTunnelDevices(owners), Layer.succeed(SqlClient, {
        query: (operation, text, params) =>
          Effect.tryPromise({ try: async () => (await pg.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
      }))))].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    // The mesh's ownership row carries its provider network: the sweep checks a tunnel's attachments against it.
    await pg.query(
      `INSERT INTO cmux_vm.resources (cmux_id, tenant_id, kind, upstream_id, created_by) VALUES ($1, $2, 'mesh', 'vpc-sweep-mesh', 'key:x')`,
      [meshId, A],
    );
    const resolved = newDeviceId();
    await claim(meshId, "s-1", resolved, at);
    await run(store.resolveAttempt(keyOf(meshId, "s-1", resolved), later(1)));
    const open = newDeviceId();
    await claim(meshId, "s-2", open, at);
    const revokedOpen = newDeviceId();
    await claim(meshId, "s-3", revokedOpen, at);
    await revokeAs(meshId, "s-3", later(1));
    const live = newDeviceId();
    await claim(meshId, "s-4", live, at);
    await run(store.commitDeviceIntent(A, "s-4", deviceRow(meshId, live), later(1)));
    await revokeAs(meshId, "s-4", later(2));
    const noIntent = newDeviceId();
    const asked = [resolved, open, revokedOpen, live, noIntent].map((deviceId) => ({ tenantId: A, deviceId }));
    expect(await sweepable(asked)).toEqual([resolved, revokedOpen].sort().map((device) => [device, "vpc-sweep-mesh"]));
    // A device whose mesh has no recorded network is never named: the sweep could not check its attachments.
    const unrecorded = newMeshId();
    const orphanedMesh = newDeviceId();
    await claim(unrecorded, "s-5", orphanedMesh, at);
    await run(store.resolveAttempt(keyOf(unrecorded, "s-5", orphanedMesh), later(1)));
    expect(await sweepable([{ tenantId: A, deviceId: orphanedMesh }])).toEqual([]);
    // The tenant is part of the match: another tenant's name for the same device names nothing.
    expect(await sweepable([{ tenantId: "team_other", deviceId: resolved }])).toEqual([]);
    expect(await sweepable([])).toEqual([]);
  });

  it("releases a revoked intent's claim only once its attempt is resolved (its deletion confirmed)", async () => {
    const meshId = newMeshId();
    const device = newDeviceId();
    await claim(meshId, "i-17", device, at);
    await run(store.commitDeviceIntent(A, "i-17", deviceRow(meshId, device), later(1)));
    await run(store.revokeIntentOfDevice(A, device, later(2)));
    const stateOf = async () => (await run(store.findDeviceIntent(A, meshId, "i-17"))).pipe(Option.map((row) => [row.committedAt === null, row.deviceId]));
    // The tunnel's delete is not confirmed yet: the revoked row keeps its commit, so a revoke still deletes the device.
    await run(store.releaseDeviceIntent(keyOf(meshId, "i-17", device)));
    expect(await stateOf()).toEqual(Option.some([false, device]));
    await run(store.resolveAttempt(keyOf(meshId, "i-17", device), later(3)));
    await run(store.releaseDeviceIntent(keyOf(meshId, "i-17", device)));
    expect(await stateOf()).toEqual(Option.some([true, null]));
    expect(await claim(meshId, "i-17", newDeviceId(), later(INTENT_TOMBSTONE_MS + 3))).toBe(true);
  });

  it("clears a commit revoked during its rollback whichever confirms the delete: the rollback, or a later revoke's reconcile", async () => {
    // Two meshes: each case commits a device with the same WireGuard key, which is unique per mesh.
    const meshOf: Record<string, string> = { "i-18": newMeshId(), "i-19": newMeshId() };
    const stateOf = async (intentId: string) =>
      (await run(store.findDeviceIntent(A, meshOf[intentId] ?? "", intentId))).pipe(Option.map((row) => [row.committedAt === null, row.deviceId === null, row.revokedAt === null]));
    // The rollback confirms the delete: it resolves the attempt, then gives the claim back.
    let meshId = meshOf["i-18"] ?? "";
    const rolled = newDeviceId();
    await claim(meshId, "i-18", rolled, at);
    await run(store.commitDeviceIntent(A, "i-18", deviceRow(meshId, rolled), later(1)));
    await revokeAs(meshId, "i-18", later(2));
    await run(store.uncommitDeviceIntent(keyOf(meshId, "i-18", rolled)));
    expect(await stateOf("i-18")).toEqual(Option.some([false, false, false]));
    await run(store.resolveAttempt(keyOf(meshId, "i-18", rolled), later(3)));
    await run(store.releaseDeviceIntent(keyOf(meshId, "i-18", rolled)));
    expect(await stateOf("i-18")).toEqual(Option.some([true, true, false]));
    // The rollback's delete failed: the attempt stays open, and the revoke's reconcile releases it once it deletes the tunnel.
    meshId = meshOf["i-19"] ?? "";
    const stuck = newDeviceId();
    await claim(meshId, "i-19", stuck, at);
    await run(store.commitDeviceIntent(A, "i-19", deviceRow(meshId, stuck), later(1)));
    await revokeAs(meshId, "i-19", later(2));
    await run(store.uncommitDeviceIntent(keyOf(meshId, "i-19", stuck)));
    expect(await openOf(meshId, "i-19")).toEqual([stuck]);
    await run(store.releaseCommitOfDevice(A, stuck, later(3)));
    expect(await stateOf("i-19")).toEqual(Option.some([true, true, false]));
    expect(await openOf(meshId, "i-19")).toEqual([]);
    // Either way the tombstone alone decides when the intent is usable again.
    for (const intentId of ["i-18", "i-19"]) {
      meshId = meshOf[intentId] ?? "";
      expect(await claim(meshId, intentId, newDeviceId(), later(INTENT_TOMBSTONE_MS))).toBe(false);
      expect(await claim(meshId, intentId, newDeviceId(), later(INTENT_TOMBSTONE_MS + 3))).toBe(true);
    }
  });

  it("keeps a tombstone 7 days, written before any enroll or by a device's delete", async () => {
    const meshId = newMeshId();
    await revokeAs(meshId, "i-5", at);
    expect(await claim(meshId, "i-5", newDeviceId(), later(INTENT_TOMBSTONE_MS - 1))).toBe(false);
    expect(await claim(meshId, "i-5", newDeviceId(), later(INTENT_TOMBSTONE_MS))).toBe(true);

    const device = newDeviceId();
    await claim(meshId, "i-6", device, at);
    await run(store.commitDeviceIntent(A, "i-6", deviceRow(meshId, device), at));
    await run(store.revokeIntentOfDevice(A, device, later(1)));
    expect(intentState(await run(store.findDeviceIntent(A, meshId, "i-6")), later(2))).toBe("revoked");
    // A release never lifts a tombstone.
    await run(store.releaseDeviceIntent(keyOf(meshId, "i-6", device)));
    expect(intentState(await run(store.findDeviceIntent(A, meshId, "i-6")), later(3))).toBe("revoked");
    expect(Option.isNone(await run(store.findDeviceIntent(TenantId.make("team_bravo"), meshId, "i-6")))).toBe(true);
  });

  it("writes a revoke only for the claimant or a tenant admin carrying the row's labels and allowed every attempt's device", async () => {
    const meshId = newMeshId();
    const labels = { role: "cloud" };
    const device = newDeviceId();
    await claim(meshId, "i-7", device, at, "key:b", labels);
    // Another principal, an admin with other labels, a non-admin with the labels, and an admin confined to other
    // resources (even the mesh itself) change nothing.
    for (const caller of [
      { ref: "key:a", labels: {}, admin: false, allowlist: null },
      { ref: "key:a", labels: { role: "other" }, admin: true, allowlist: null },
      { ref: "key:a", labels, admin: false, allowlist: null },
      { ref: "key:a", labels: {}, admin: true, allowlist: [meshId] },
    ]) {
      expect(Option.isNone(await run(store.revokeDeviceIntent(A, meshId, "i-7", caller, later(1))))).toBe(true);
    }
    expect((await run(store.findDeviceIntent(A, meshId, "i-7"))).pipe(Option.map((row) => row.revokedAt))).toEqual(Option.some(null));
    // An admin allowed the device may; so may an admin without required labels (the row's labels contain the empty
    // set), and the claimant.
    expect((await revokeAs(meshId, "i-7", later(2), { ref: "key:a", labels: {}, admin: true, allowlist: [meshId, device] })).revokedAt).not.toBeNull();
    expect((await revokeAs(meshId, "i-7", later(3), { ref: "key:a", labels: {}, admin: true, allowlist: null })).revokedAt).not.toBeNull();
    expect((await revokeAs(meshId, "i-7", later(4), { ref: "key:b", labels, admin: false, allowlist: null })).createdBy).toBe("key:b");
    // An unused intent's tombstone records its revoker, whom a later claim by someone else cannot displace.
    const tomb = await revokeAs(meshId, "i-8", at, { ref: "key:a", labels: {}, admin: false, allowlist: null });
    expect(tomb).toMatchObject({ createdBy: "key:a", deviceId: null, attemptDeviceIds: [] });
    expect(await claim(meshId, "i-8", newDeviceId(), later(1), "key:b")).toBe(false);
  });

  it("lets only an authorized caller claim an existing intent or end its claim, and never a committed or live one", async () => {
    const meshId = newMeshId();
    const labels = { role: "cloud" };
    const first = newDeviceId();
    await claim(meshId, "i-9", first, at, "key:b", labels);
    await run(store.markAttemptSent(keyOf(meshId, "i-9", first), later(1)));
    const stranger = { ref: "key:a", labels: {}, admin: false, allowlist: null };
    const confined = { ref: "key:a", labels: {}, admin: true, allowlist: [meshId] };
    const claimant = { ref: "key:b", labels, admin: false, allowlist: null };
    // A live claim is never ended, not even by its claimant, until its create finished or the stale window passed.
    expect(Option.isNone(await run(store.beginReconcile(A, meshId, "i-9", claimant, { token: "t", mode: "enroll" }, later(2))))).toBe(true);
    await run(store.finishAttempt(keyOf(meshId, "i-9", first), later(3)));
    // Once it may be ended: never by another principal or a key not allowed its device.
    for (const caller of [stranger, confined]) {
      expect(Option.isNone(await run(store.beginReconcile(A, meshId, "i-9", caller, { token: "t", mode: "enroll" }, later(4))))).toBe(true);
    }
    expect((await run(store.findDeviceIntent(A, meshId, "i-9"))).pipe(Option.map((row) => row.deviceId))).toEqual(Option.some(first));
    expect(Option.isSome(await run(store.beginReconcile(A, meshId, "i-9", claimant, { token: "t", mode: "enroll" }, later(5))))).toBe(true);
    await run(store.resolveAttempt(keyOf(meshId, "i-9", first), later(6)));
    await run(store.endReconcile(A, meshId, "i-9", "t"));
    // A free row is claimed only by an authorized caller.
    expect(await claim(meshId, "i-9", newDeviceId(), later(7), "key:a", labels)).toBe(false);
    expect(await claim(meshId, "i-9", newDeviceId(), later(7), "key:a", { role: "other" }, true)).toBe(false);
    expect(await claim(meshId, "i-9", newDeviceId(), later(7), "key:a", labels, true)).toBe(true);
    // A committed intent is never reconciled.
    const committed = newDeviceId();
    await claim(meshId, "i-10", committed, at);
    await run(store.commitDeviceIntent(A, "i-10", deviceRow(meshId, committed), later(1)));
    expect(Option.isNone(await run(store.beginReconcile(A, meshId, "i-10", owner, { token: "t", mode: "enroll" }, later(INTENT_STALE_CLAIM_MS + 1))))).toBe(true);
  });

  it("calls an absent tunnel final only once the provider answered or the send grace passed", async () => {
    const meshId = newMeshId();
    const device = newDeviceId();
    await claim(meshId, "i-11", device, at);
    await run(store.markAttemptSent(keyOf(meshId, "i-11", device), later(1)));
    await run(store.finishAttempt(keyOf(meshId, "i-11", device), later(2)));
    const finished = Option.getOrThrow(await run(store.findAttempt(keyOf(meshId, "i-11", device))));
    // Finished after a timeout: not final yet.
    expect(absenceIsFinal(finished, later(3))).toBe(false);
    expect(absenceIsFinal(finished, later(15 * 60_000 + 1))).toBe(true);
    // The provider answered with an error: final at once.
    await run(store.recordAttemptAnswer(keyOf(meshId, "i-11", device), null, later(2)));
    expect(absenceIsFinal(Option.getOrThrow(await run(store.findAttempt(keyOf(meshId, "i-11", device)))), later(3))).toBe(true);
  });

  it("binds a signed enroll message to its intent: the same message is accepted again only with that intent", async () => {
    const sql = Layer.succeed(SqlClient, {
      query: (operation, text, params) =>
        Effect.tryPromise({ try: async () => (await pg.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
    });
    const meshId = newMeshId();
    const sha = "a".repeat(64);
    const expires = later(120_000);
    const claimFor = (intentId: string, now = at) =>
      Effect.runPromise(Effect.provide(Effect.flatMap(MeshStore, (mesh) => mesh.claimSignedRequestForIntent(A, sha, "enroll", expires, now, { meshId, intentId })), sqlMeshStoreLayer.pipe(Layer.provide(sql))));
    const plain = () =>
      Effect.runPromise(Effect.provide(Effect.flatMap(MeshStore, (mesh) => mesh.claimSignedRequest(A, sha, "enroll", expires, at)), sqlMeshStoreLayer.pipe(Layer.provide(sql))));
    expect(await claimFor("i-12")).toBe("fresh");
    expect(await claimFor("i-12", later(1))).toBe("same_intent");
    expect(await claimFor("i-13", later(1))).toBe("replayed");
    expect(await plain()).toBe(false);
    // Past the message's window the binding is gone with it.
    expect(await claimFor("i-12", later(120_001))).toBe("replayed");
  });

  it("0018 is idempotent and refuses a malformed intent id", async () => {
    await pg.exec(deviceIntents);
    await expect(
      pg.query(`INSERT INTO cmux_vm.mesh_device_intents (tenant_id, mesh_cmux_id, intent_id, created_by, created_at) VALUES ('team_alpha', $1, 'has space', 'key:x', now())`, [newMeshId()]),
    ).rejects.toThrow();
    await expect(
      pg.query(
        `INSERT INTO cmux_vm.mesh_device_intent_attempts (tenant_id, mesh_cmux_id, intent_id, device_cmux_id, tunnel_cmux_id, created_at) VALUES ('team_alpha', $1, 'i', 'not-a-device', $2, now())`,
        [newMeshId(), newTunnelId()],
      ),
    ).rejects.toThrow();
  });
});
