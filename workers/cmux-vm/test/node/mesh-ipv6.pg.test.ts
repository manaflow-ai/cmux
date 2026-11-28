/**
 * The device address store (bead cx-wb5.45) against migrations 0001-0009 on
 * an in-process Postgres (PGlite): a live device's published public IPv6
 * address, read per mesh by the ACL compiler; the "address" signed-request
 * purpose; and the schema gate naming 0009 when it was not applied.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import s2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import snapshots from "../../migrations/0003_cmux_vm_snapshot_parent.sql?raw";
import mesh from "../../migrations/0004_cmux_vm_mesh.sql?raw";
import meshM2 from "../../migrations/0005_cmux_vm_mesh_m2.sql?raw";
import meshM3 from "../../migrations/0006_cmux_vm_mesh_m3.sql?raw";
import meshM4 from "../../migrations/0007_cmux_vm_mesh_m4.sql?raw";
import meshM4Retries from "../../migrations/0008_cmux_vm_mesh_m4_retries.sql?raw";
import deviceAddress from "../../migrations/0009_cmux_vm_mesh_device_address.sql?raw";
import { MeshStore, sqlMeshStoreLayer } from "../../src/db/mesh.ts";
import { checkSchema } from "../../src/db/schema-check.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { newDeviceId, newMeshId, newTunnelId, TenantId } from "../../src/lib/ids.ts";

const BEFORE = [ownership, s2, snapshots, mesh, meshM2, meshM3, meshM4, meshM4Retries];
const ALL = [...BEFORE, deviceAddress];

const sqlOver = (db: PGlite) =>
  Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({ try: async () => (await db.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
  });
let pg: PGlite;
let layer: Layer.Layer<MeshStore>;
const run = <A, E>(effect: Effect.Effect<A, E, MeshStore>) => Effect.runPromise(Effect.provide(effect, layer));

const T = TenantId.make("team_alpha");
const t0 = Date.UTC(2026, 9, 8, 12, 0);
const at = (ms: number) => new Date(t0 + ms);
const device = (meshId: string, n: number) => ({
  deviceId: newDeviceId(),
  meshId,
  tunnelId: newTunnelId(),
  name: "d",
  wgPublicKey: btoa(`device-public-key-${String(n).padStart(14, "0")}`),
  installPublicKey: null,
  createdBy: "user:user_ada",
  createdAt: at(n),
});

beforeEach(async () => {
  pg = new PGlite();
  for (const migration of ALL) await pg.exec(migration);
  layer = sqlMeshStoreLayer.pipe(Layer.provide(sqlOver(pg)));
});

describe("migration 0009", () => {
  it("is idempotent", async () => {
    await pg.exec(deviceAddress);
    await pg.exec(deviceAddress);
  });

  it("the rollback leaves the 0008 schema, and 0009 applies again after it", async () => {
    await pg.exec(`ALTER TABLE cmux_vm.mesh_devices DROP COLUMN IF EXISTS public_ipv6, DROP COLUMN IF EXISTS public_ipv6_at;
      ALTER TABLE cmux_vm.mesh_signed_requests DROP CONSTRAINT IF EXISTS mesh_signed_requests_purpose_check;
      ALTER TABLE cmux_vm.mesh_signed_requests ADD CONSTRAINT mesh_signed_requests_purpose_check CHECK (purpose IN ('enroll', 'rotate-key', 'peers', 'tunnel'));`);
    expect(await Effect.runPromise(Effect.provide(checkSchema, sqlOver(pg)))).toContain("cmux_vm.mesh_devices.public_ipv6: missing");
    await pg.exec(deviceAddress);
    expect(await Effect.runPromise(Effect.provide(checkSchema, sqlOver(pg)))).toEqual([]);
  });

  it("the schema gate names the column when 0009 was not applied", async () => {
    const old = new PGlite();
    for (const migration of BEFORE) await old.exec(migration);
    expect(await Effect.runPromise(Effect.provide(checkSchema, sqlOver(old)))).toEqual(["cmux_vm.mesh_devices.public_ipv6: missing"]);
  });

  it("refuses a stored address that is not a plain IPv6 literal", async () => {
    const meshId = newMeshId();
    const row = device(meshId, 1);
    await run(Effect.flatMap(MeshStore, (store) => store.recordDevice(T, row)));
    await expect(pg.query("UPDATE cmux_vm.mesh_devices SET public_ipv6 = '2600::1/64' WHERE device_cmux_id = $1", [row.deviceId])).rejects.toThrow();
  });
});

describe("device addresses", () => {
  it("stores, replaces and clears a live device's address, and lists the mesh's live addresses", async () => {
    const meshId = newMeshId();
    const one = device(meshId, 1);
    const two = device(meshId, 2);
    const elsewhere = device(newMeshId(), 3);
    await run(
      Effect.gen(function* () {
        const store = yield* MeshStore;
        for (const row of [one, two, elsewhere]) yield* store.recordDevice(T, row);
        expect(yield* store.setDeviceAddress(T, one.deviceId, "2600:1700:abcd:1::5", at(10))).toBe(true);
        expect(yield* store.setDeviceAddress(T, two.deviceId, "2a01:4f8::1", at(11))).toBe(true);
        expect(yield* store.setDeviceAddress(T, elsewhere.deviceId, "2a01:4f8::2", at(12))).toBe(true);
        expect(yield* store.setDeviceAddress(T, one.deviceId, "2600:1700:abcd:2::9", at(13))).toBe(true);
        expect(yield* store.setDeviceAddress(T, two.deviceId, null, at(14))).toBe(true);
        expect([...(yield* store.deviceAddresses(T, meshId))]).toEqual([[one.deviceId, "2600:1700:abcd:2::9"]]);
      }),
    );
  });

  it("refuses an address for a deleted device or another tenant's device", async () => {
    const meshId = newMeshId();
    const gone = device(meshId, 1);
    const theirs = device(meshId, 2);
    await run(
      Effect.gen(function* () {
        const store = yield* MeshStore;
        yield* store.recordDevice(T, gone);
        yield* store.recordDevice(TenantId.make("team_bravo"), theirs);
        yield* store.markDeviceDeleted(T, gone.deviceId, at(5));
        expect(yield* store.setDeviceAddress(T, gone.deviceId, "2600::1", at(10))).toBe(false);
        expect(yield* store.setDeviceAddress(T, theirs.deviceId, "2600::1", at(10))).toBe(false);
        expect([...(yield* store.deviceAddresses(T, meshId))]).toEqual([]);
      }),
    );
  });

  it("accepts the address purpose for a signed request claim", async () => {
    const claimed = await run(Effect.flatMap(MeshStore, (store) => store.claimSignedRequest(T, "a".repeat(64), "address", at(120_000), at(0))));
    expect(claimed).toBe(true);
  });
});
