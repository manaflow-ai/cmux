/**
 * Enroll intents (migration 0018) against the real migration on an in-process Postgres (PGlite): the claim, the
 * commit that is the device insert, the tombstone, the release, and their expiries.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Option } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import s2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import snapshots from "../../migrations/0003_cmux_vm_snapshot_parent.sql?raw";
import mesh from "../../migrations/0004_cmux_vm_mesh.sql?raw";
import meshM2 from "../../migrations/0005_cmux_vm_mesh_m2.sql?raw";
import meshM3 from "../../migrations/0006_cmux_vm_mesh_m3.sql?raw";
import deviceIntents from "../../migrations/0018_cmux_vm_mesh_device_intents.sql?raw";
import { INTENT_STALE_CLAIM_MS, INTENT_TOMBSTONE_MS, intentState, sqlDeviceIntents, type DeviceIntentStore } from "../../src/db/mesh-intents.ts";
import type { MeshDeviceRow } from "../../src/db/mesh.ts";
import { StoreError } from "../../src/db/sql.ts";
import { newDeviceId, newMeshId, newTunnelId, TenantId } from "../../src/lib/ids.ts";

const A = TenantId.make("team_alpha");
const at = new Date(Date.UTC(2026, 10, 9, 0, 0));
const later = (ms: number) => new Date(at.getTime() + ms);
let pg: PGlite;
let store: DeviceIntentStore;
const run = <A>(effect: Effect.Effect<A, StoreError>) => Effect.runPromise(effect);

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

describe("mesh device intents", () => {
  it("commits the device row only for the live claim, and a tombstone before the commit inserts nothing", async () => {
    const meshId = newMeshId();
    const first = newDeviceId();
    expect(await run(store.claimDeviceIntent(A, meshId, "i-1", first, "key:x", at))).toBe(true);
    // A second claim while the first is live is refused.
    expect(await run(store.claimDeviceIntent(A, meshId, "i-1", newDeviceId(), "key:x", later(1)))).toBe(false);
    const revoked = await run(store.revokeDeviceIntent(A, meshId, "i-1", "key:x", later(2)));
    expect(revoked).toMatchObject({ deviceId: first, committedAt: null });
    expect(revoked.revokedAt).not.toBeNull();
    expect(await run(store.commitDeviceIntent(A, "i-1", deviceRow(meshId, first), later(3)))).toBe(false);
    expect(await devicesOf()).toEqual([]);
    expect(intentState(await run(store.findDeviceIntent(A, meshId, "i-1")), later(4))).toBe("revoked");
    // Idempotent: a second revoke keeps the first tombstone's time.
    expect((await run(store.revokeDeviceIntent(A, meshId, "i-1", "key:x", later(5)))).revokedAt).toEqual(revoked.revokedAt);
  });

  it("lets a revoke after the commit see the committed device", async () => {
    const meshId = newMeshId();
    const device = newDeviceId();
    await run(store.claimDeviceIntent(A, meshId, "i-2", device, "key:x", at));
    expect(await run(store.commitDeviceIntent(A, "i-2", deviceRow(meshId, device), later(1)))).toBe(true);
    expect(await devicesOf()).toEqual([{ device_cmux_id: device }]);
    expect(intentState(await run(store.findDeviceIntent(A, meshId, "i-2")), later(2))).toBe("committed");
    expect(await run(store.commitDeviceIntent(A, "i-2", deviceRow(meshId, device), later(2)))).toBe(false);
    const revoked = await run(store.revokeDeviceIntent(A, meshId, "i-2", "key:x", later(3)));
    expect(revoked.deviceId).toBe(device);
    expect(revoked.committedAt).not.toBeNull();
  });

  it("frees a released claim and a stale one, and a stale create's commit then matches nothing", async () => {
    const meshId = newMeshId();
    const first = newDeviceId();
    await run(store.claimDeviceIntent(A, meshId, "i-3", first, "key:x", at));
    await run(store.releaseDeviceIntent(A, meshId, "i-3", first));
    expect(intentState(await run(store.findDeviceIntent(A, meshId, "i-3")), at)).toBe("absent");
    const second = newDeviceId();
    expect(await run(store.claimDeviceIntent(A, meshId, "i-3", second, "key:x", later(1)))).toBe(true);
    const third = newDeviceId();
    expect(await run(store.claimDeviceIntent(A, meshId, "i-3", third, "key:x", later(INTENT_STALE_CLAIM_MS)))).toBe(false);
    expect(await run(store.claimDeviceIntent(A, meshId, "i-3", third, "key:x", later(INTENT_STALE_CLAIM_MS + 2)))).toBe(true);
    expect(await run(store.commitDeviceIntent(A, "i-3", deviceRow(meshId, second), later(INTENT_STALE_CLAIM_MS + 3)))).toBe(false);
    expect(await run(store.commitDeviceIntent(A, "i-3", deviceRow(meshId, third), later(INTENT_STALE_CLAIM_MS + 3)))).toBe(true);
  });

  it("keeps a tombstone 7 days, written before any enroll or by a device's delete", async () => {
    const meshId = newMeshId();
    await run(store.revokeDeviceIntent(A, meshId, "i-4", "key:x", at));
    expect(await run(store.claimDeviceIntent(A, meshId, "i-4", newDeviceId(), "key:x", later(INTENT_TOMBSTONE_MS - 1)))).toBe(false);
    expect(await run(store.claimDeviceIntent(A, meshId, "i-4", newDeviceId(), "key:x", later(INTENT_TOMBSTONE_MS)))).toBe(true);

    const device = newDeviceId();
    await run(store.claimDeviceIntent(A, meshId, "i-5", device, "key:x", at));
    await run(store.commitDeviceIntent(A, "i-5", deviceRow(meshId, device), at));
    await run(store.revokeIntentOfDevice(A, device, later(1)));
    expect(intentState(await run(store.findDeviceIntent(A, meshId, "i-5")), later(2))).toBe("revoked");
    // A release never lifts a tombstone.
    await run(store.releaseDeviceIntent(A, meshId, "i-5", device));
    expect(intentState(await run(store.findDeviceIntent(A, meshId, "i-5")), later(3))).toBe("revoked");
    expect(Option.isNone(await run(store.findDeviceIntent(TenantId.make("team_bravo"), meshId, "i-5")))).toBe(true);
  });

  it("0018 is idempotent and refuses a malformed intent id", async () => {
    await pg.exec(deviceIntents);
    await expect(
      pg.query(`INSERT INTO cmux_vm.mesh_device_intents (tenant_id, mesh_cmux_id, intent_id, created_by, created_at) VALUES ('team_alpha', $1, 'has space', 'key:x', now())`, [newMeshId()]),
    ).rejects.toThrow();
  });
});
