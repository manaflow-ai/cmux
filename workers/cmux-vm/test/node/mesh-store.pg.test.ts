/**
 * The mesh store against migrations 0001-0004 on an in-process Postgres
 * (PGlite). No network database is involved.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer, Option } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import s2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import snapshots from "../../migrations/0003_cmux_vm_snapshot_parent.sql?raw";
import mesh from "../../migrations/0004_cmux_vm_mesh.sql?raw";
import { MeshStore, sqlMeshStoreLayer } from "../../src/db/mesh.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { AuditStore, OwnershipStore, sqlStoresLayer } from "../../src/db/stores.ts";
import { newDeviceId, newMeshId, newTunnelId, newVmId, TenantId, UpstreamId } from "../../src/lib/ids.ts";

type Stores = MeshStore | OwnershipStore | AuditStore;

let pg: PGlite;
let layer: Layer.Layer<Stores>;
const run = <A, E>(effect: Effect.Effect<A, E, Stores>) => Effect.runPromise(Effect.provide(effect, layer));

const A = TenantId.make("team_alpha");
const B = TenantId.make("team_bravo");
const KEY = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDE=";
const at = new Date(Date.UTC(2026, 9, 7, 0, 0));

beforeEach(async () => {
  pg = new PGlite();
  for (const migration of [ownership, s2, snapshots, mesh]) await pg.exec(migration);
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({
        try: async () => (await pg.query(text, [...params])).rows,
        catch: (cause) => new StoreError({ operation, cause }),
      }),
  });
  layer = Layer.mergeAll(sqlMeshStoreLayer, sqlStoresLayer).pipe(Layer.provide(sql));
});

describe("migration 0004", () => {
  it("is idempotent", async () => {
    await pg.exec(mesh);
    await pg.exec(mesh);
  });

  it("keeps accepting VM and snapshot rows, and accepts mesh, device and tunnel rows with matching prefixes only", async () => {
    const base = { tenantId: A, createdBy: "key:test", createdAt: at, displayName: null, labels: {} };
    await run(
      Effect.gen(function* () {
        const store = yield* OwnershipStore;
        yield* store.record({ ...base, kind: "vm", cmuxId: newVmId(), upstreamId: UpstreamId.make("vm-1") });
        yield* store.record({ ...base, kind: "mesh", cmuxId: newMeshId(), upstreamId: UpstreamId.make("vpc-1") });
        yield* store.record({ ...base, kind: "device", cmuxId: newDeviceId(), upstreamId: UpstreamId.make("tun-1") });
        yield* store.record({ ...base, kind: "tunnel", cmuxId: newTunnelId(), upstreamId: UpstreamId.make("tun-1") });
      }),
    );
    await expect(
      run(Effect.flatMap(OwnershipStore, (store) => store.record({ ...base, kind: "mesh", cmuxId: newDeviceId(), upstreamId: UpstreamId.make("vpc-2") }))),
    ).rejects.toThrow();
  });

  it("audits mesh ids", async () => {
    await run(
      Effect.flatMap(AuditStore, (store) => store.append({ tenantId: A, actor: "key:x", action: "mesh.create", cmuxId: newMeshId(), outcome: "ok", at })),
    );
  });
});

describe("mesh store", () => {
  it("gives each /20 slot to one mesh only", async () => {
    const first = newMeshId();
    const second = newMeshId();
    const claims = await run(
      Effect.gen(function* () {
        const store = yield* MeshStore;
        return [
          yield* store.claimSlot(A, first, 7, "10.128.112.0/20"),
          yield* store.claimSlot(B, second, 7, "10.128.112.0/20"),
          yield* store.claimSlot(B, second, 8, "10.128.128.0/20"),
        ];
      }),
    );
    expect(claims).toEqual([true, false, true]);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.cidrOf(A, first)))).toEqual(Option.some("10.128.112.0/20"));
    expect(await run(Effect.flatMap(MeshStore, (store) => store.cidrOf(B, first)))).toEqual(Option.none());
  });

  it("keys devices, members, ACL versions and rules by tenant", async () => {
    const meshId = newMeshId();
    const deviceId = newDeviceId();
    const tunnelId = newTunnelId();
    const vmId = newVmId();
    const result = await run(
      Effect.gen(function* () {
        const store = yield* MeshStore;
        yield* store.recordDevice(A, { deviceId, meshId, tunnelId, name: "laptop", wgPublicKey: KEY, createdBy: "key:x", createdAt: at });
        const attached = yield* store.attachMember(A, { meshId, vmId, ipv4: "10.128.0.5", attachedAt: at });
        const again = yield* store.attachMember(A, { meshId: newMeshId(), vmId, ipv4: null, attachedAt: at });
        const firstAcl = yield* store.insertAcl(A, meshId, { version: 1, document: { rules: [] }, sha256: "0".repeat(64), author: "key:x", createdAt: at });
        const sameVersion = yield* store.insertAcl(A, meshId, { version: 1, document: { rules: [] }, sha256: "1".repeat(64), author: "key:y", createdAt: at });
        yield* store.recordRule(A, { meshId, key: `${deviceId}>${vmId}:icmp:*`, upstreamRuleId: "fwr-1", deviceId, vmId, protocol: "icmp", port: null, createdAt: at });
        return {
          attached,
          again,
          firstAcl,
          sameVersion,
          deviceA: yield* store.getDevice(A, deviceId),
          deviceB: yield* store.getDevice(B, deviceId),
          byTunnel: yield* store.getDeviceByTunnel(A, tunnelId),
          membersB: yield* store.listMembers(B, meshId),
          rulesA: yield* store.listRules(A, meshId),
          rulesB: yield* store.listRules(B, meshId),
          acl: yield* store.currentAcl(A, meshId),
          recent: yield* store.aclVersionsSince(A, meshId, new Date(at.getTime() - 1000)),
        };
      }),
    );
    expect(result.attached).toBe(true);
    expect(result.again).toBe(false);
    expect(result.firstAcl).toBe(true);
    expect(result.sameVersion).toBe(false);
    expect(Option.isSome(result.deviceA)).toBe(true);
    expect(Option.isNone(result.deviceB)).toBe(true);
    expect(Option.map(result.byTunnel, (row) => row.deviceId)).toEqual(Option.some(deviceId));
    expect(result.membersB).toEqual([]);
    expect(result.rulesA.map((rule) => rule.port)).toEqual([null]);
    expect(result.rulesB).toEqual([]);
    expect(Option.map(result.acl, (row) => row.version)).toEqual(Option.some(1));
    expect(result.recent).toHaveLength(1);
  });

  it("forgets deleted devices and rules", async () => {
    const meshId = newMeshId();
    const deviceId = newDeviceId();
    const vmId = newVmId();
    const after = await run(
      Effect.gen(function* () {
        const store = yield* MeshStore;
        yield* store.recordDevice(A, { deviceId, meshId, tunnelId: newTunnelId(), name: "laptop", wgPublicKey: KEY, createdBy: "key:x", createdAt: at });
        const key = `${deviceId}>${vmId}:tcp:22`;
        yield* store.recordRule(A, { meshId, key, upstreamRuleId: "fwr-2", deviceId, vmId, protocol: "tcp", port: 22, createdAt: at });
        yield* store.markDeviceDeleted(A, deviceId, at);
        yield* store.markRuleDeleted(A, meshId, key, at);
        return { devices: yield* store.listDevices(A, meshId), rules: yield* store.listRules(A, meshId) };
      }),
    );
    expect(after).toEqual({ devices: [], rules: [] });
  });
});
