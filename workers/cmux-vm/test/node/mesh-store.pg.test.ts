/**
 * The mesh store against migrations 0001-0006 on an in-process Postgres
 * (PGlite). No network database is involved.
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
  for (const migration of [ownership, s2, snapshots, mesh, meshM2, meshM3]) await pg.exec(migration);
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
      Effect.flatMap(AuditStore, (store) => store.append({ tenantId: A, actor: "key:x", ownerActor: null, action: "mesh.create", cmuxId: newMeshId(), outcome: "ok", at })),
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
        yield* store.recordDevice(A, { deviceId, meshId, tunnelId, name: "laptop", wgPublicKey: KEY, installPublicKey: null, createdBy: "key:x", createdAt: at });
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
        yield* store.recordDevice(A, { deviceId, meshId, tunnelId: newTunnelId(), name: "laptop", wgPublicKey: KEY, installPublicKey: null, createdBy: "key:x", createdAt: at });
        const key = `${deviceId}>${vmId}:tcp:22`;
        yield* store.recordRule(A, { meshId, key, upstreamRuleId: "fwr-2", deviceId, vmId, protocol: "tcp", port: 22, createdAt: at });
        yield* store.markDeviceDeleted(A, deviceId, at);
        yield* store.markRuleDeleted(A, meshId, key, at);
        return { devices: yield* store.listDevices(A, meshId), rules: yield* store.listRules(A, meshId) };
      }),
    );
    expect(after).toEqual({ devices: [], rules: [] });
  });

  it("M2 (0005): install keys, key rotation, replay claims and one-time codes", async () => {
    const meshId = newMeshId();
    const first = newDeviceId();
    const second = newDeviceId();
    const INSTALL = "BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=";
    const KEY_2 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDI=";
    const KEY_3 = "dGVzdC1kZXZpY2UtcHVibGljLWtleS0wMDAwMDAwMDM=";
    const hash = (n: number) => n.toString(16).padStart(64, "0");
    const later = new Date(at.getTime() + 60_000);
    const result = await run(
      Effect.gen(function* () {
        const store = yield* MeshStore;
        yield* store.recordDevice(A, { deviceId: first, meshId, tunnelId: newTunnelId(), name: "a", wgPublicKey: KEY, installPublicKey: INSTALL, createdBy: "key:x", createdAt: at });
        yield* store.recordDevice(A, { deviceId: second, meshId, tunnelId: newTunnelId(), name: "b", wgPublicKey: KEY_2, installPublicKey: null, createdBy: "key:x", createdAt: at });
        const rotated = yield* store.updateDeviceKey(A, first, KEY_3, at);
        const taken = yield* store.updateDeviceKey(A, first, KEY_2, at);
        const foreign = yield* store.updateDeviceKey(B, first, KEY, at);
        const claim = (n: number, expires: Date, now: Date) => store.claimSignedRequest(A, hash(n), "enroll", expires, now);
        const fresh = yield* claim(1, later, at);
        const replay = yield* claim(1, later, at);
        // Expired claims are pruned on the next claim, so storage stays bounded.
        yield* claim(2, at, at);
        yield* claim(3, later, new Date(at.getTime() + 1));
        const code = { codeSha256: hash(9), tenantId: A, meshId, createdBy: "user:u1", createdAt: at, expiresAt: new Date(at.getTime() + 600_000) };
        yield* store.insertEnrollmentCode(code);
        const otherMesh = yield* store.findEnrollmentCode(hash(9), newMeshId(), at);
        const found = yield* store.findEnrollmentCode(hash(9), meshId, at);
        const expired = yield* store.findEnrollmentCode(hash(9), meshId, new Date(at.getTime() + 600_001));
        const used = yield* store.consumeEnrollmentCode(hash(9), meshId, later);
        const usedAgain = yield* store.consumeEnrollmentCode(hash(9), meshId, later);
        yield* store.recordEnrollmentCodeDevice(hash(9), first);
        return {
          rotated,
          taken,
          foreign,
          key: Option.map(yield* store.getDevice(A, first), (row) => [row.wgPublicKey, row.installPublicKey]),
          fresh,
          replay,
          found: Option.map(found, (row) => [row.tenantId, row.createdBy]),
          otherMesh,
          expired,
          used,
          usedAgain,
          since: yield* store.enrollmentCodesSince(A, meshId, new Date(at.getTime() - 1)),
          sinceB: yield* store.enrollmentCodesSince(B, meshId, new Date(at.getTime() - 1)),
        };
      }),
    );
    expect(result.rotated).toBe(true);
    expect(result.taken).toBe(false);
    expect(result.foreign).toBe(false);
    expect(result.key).toEqual(Option.some([KEY_3, INSTALL]));
    expect(result.fresh).toBe(true);
    expect(result.replay).toBe(false);
    expect((await pg.query("SELECT message_sha256 FROM cmux_vm.mesh_signed_requests ORDER BY 1")).rows).toEqual([{ message_sha256: hash(1) }, { message_sha256: hash(3) }]);
    expect(result.found).toEqual(Option.some([A, "user:u1"]));
    expect(Option.isNone(result.otherMesh)).toBe(true);
    expect(Option.isNone(result.expired)).toBe(true);
    expect(result.used).toBe(true);
    expect(result.usedAgain).toBe(false);
    expect(result.since).toHaveLength(1);
    expect(result.sinceB).toEqual([]);
    expect((await pg.query("SELECT device_cmux_id FROM cmux_vm.mesh_enrollment_codes")).rows).toEqual([{ device_cmux_id: first }]);
  });

  it("0005 refuses a code valid for more than 10 minutes and a malformed install key", async () => {
    await expect(
      pg.query(
        `INSERT INTO cmux_vm.mesh_enrollment_codes (code_sha256, tenant_id, mesh_cmux_id, created_by, created_at, expires_at)
         VALUES ($1, 'team_alpha', $2, 'user:u', now(), now() + interval '11 minutes')`,
        ["a".repeat(64), newMeshId()],
      ),
    ).rejects.toThrow();
    await expect(
      pg.query(
        `INSERT INTO cmux_vm.mesh_devices (device_cmux_id, tenant_id, mesh_cmux_id, tunnel_cmux_id, name, wg_public_key, install_public_key, created_by)
         VALUES ($1, 'team_alpha', $2, $3, 'x', $4, 'not-a-key', 'key:x')`,
        [newDeviceId(), newMeshId(), newTunnelId(), KEY],
      ),
    ).rejects.toThrow();
  });

  it("M3 (0006): device-signed purposes, devices found by id alone, codes burned and restored", async () => {
    const meshId = newMeshId();
    const deviceId = newDeviceId();
    const INSTALL = "BGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk=";
    const hash = (n: number) => n.toString(16).padStart(64, "0");
    const later = new Date(at.getTime() + 60_000);
    const result = await run(
      Effect.gen(function* () {
        const store = yield* MeshStore;
        yield* store.recordDevice(A, { deviceId, meshId, tunnelId: newTunnelId(), name: "a", wgPublicKey: KEY, installPublicKey: INSTALL, createdBy: "key:x", createdAt: at });
        const peers = yield* store.claimSignedRequest(A, hash(1), "peers", later, at);
        const tunnel = yield* store.claimSignedRequest(A, hash(2), "tunnel", later, at);
        const byId = yield* store.findDeviceForSignedRequest(deviceId);
        const unknown = yield* store.findDeviceForSignedRequest(newDeviceId());

        const code = (n: number) => ({ codeSha256: hash(n), tenantId: A, meshId, createdBy: "key:x", createdAt: at, expiresAt: new Date(at.getTime() + 600_000) });
        // Burn: an unused code can no longer be found or used, even if restored afterwards.
        yield* store.insertEnrollmentCode(code(10));
        yield* store.burnEnrollmentCode(hash(10), later);
        const burned = yield* store.findEnrollmentCode(hash(10), meshId, later);
        yield* store.restoreEnrollmentCode(hash(10), later);
        const burnedRestored = yield* store.findEnrollmentCode(hash(10), meshId, later);
        // Restore: a consumed code is usable again, only for the claim it made.
        yield* store.insertEnrollmentCode(code(11));
        const claimed = yield* store.consumeEnrollmentCode(hash(11), meshId, later);
        yield* store.restoreEnrollmentCode(hash(11), new Date(later.getTime() + 1));
        const wrongClaim = yield* store.findEnrollmentCode(hash(11), meshId, later);
        yield* store.restoreEnrollmentCode(hash(11), later);
        const restored = yield* store.findEnrollmentCode(hash(11), meshId, later);
        // A claim that consumed a code burned meanwhile stays dead after restore.
        yield* store.insertEnrollmentCode(code(12));
        yield* store.consumeEnrollmentCode(hash(12), meshId, later);
        yield* store.burnEnrollmentCode(hash(12), new Date(later.getTime() + 5));
        yield* store.restoreEnrollmentCode(hash(12), later);
        const burnedWhileClaimed = yield* store.findEnrollmentCode(hash(12), meshId, new Date(later.getTime() + 10));
        // A code that made a device is never burned or restored.
        yield* store.insertEnrollmentCode(code(13));
        yield* store.consumeEnrollmentCode(hash(13), meshId, later);
        yield* store.recordEnrollmentCodeDevice(hash(13), deviceId);
        yield* store.restoreEnrollmentCode(hash(13), later);
        yield* store.burnEnrollmentCode(hash(13), later);
        // Burning an unknown hash is a no-op.
        yield* store.burnEnrollmentCode(hash(99), later);
        return {
          peers,
          tunnel,
          byId: Option.map(byId, (row) => [row.tenantId, row.deviceId, row.installPublicKey]),
          unknown,
          burned,
          burnedRestored,
          claimed,
          wrongClaim,
          restored,
          burnedWhileClaimed,
        };
      }),
    );
    expect(result.peers).toBe(true);
    expect(result.tunnel).toBe(true);
    expect(result.byId).toEqual(Option.some([A, deviceId, INSTALL]));
    expect(Option.isNone(result.unknown)).toBe(true);
    expect(Option.isNone(result.burned)).toBe(true);
    expect(Option.isNone(result.burnedRestored)).toBe(true);
    expect(result.claimed).toBe(true);
    expect(Option.isNone(result.wrongClaim)).toBe(true);
    expect(Option.isSome(result.restored)).toBe(true);
    expect(Option.isNone(result.burnedWhileClaimed)).toBe(true);
    const made = await pg.query<{ used_at: unknown; device_cmux_id: string }>(`SELECT used_at, device_cmux_id FROM cmux_vm.mesh_enrollment_codes WHERE code_sha256 = $1`, [hash(13)]);
    expect(made.rows[0]?.device_cmux_id).toBe(deviceId);
    expect(made.rows[0]?.used_at).not.toBeNull();
  });

  it("0006 is idempotent, keeps the M2 purposes and refuses unknown ones", async () => {
    await pg.exec(meshM3);
    await pg.exec(meshM3);
    const insert = (purpose: string, n: number) =>
      pg.query(`INSERT INTO cmux_vm.mesh_signed_requests (message_sha256, tenant_id, purpose, expires_at) VALUES ($1, 'team_alpha', $2, now())`, [
        n.toString(16).padStart(64, "0"),
        purpose,
      ]);
    for (const [index, purpose] of ["enroll", "rotate-key", "peers", "tunnel"].entries()) await insert(purpose, index + 1);
    await expect(insert("delete", 9)).rejects.toThrow();
  });
});

