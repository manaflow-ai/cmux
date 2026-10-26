import domainsTls from "../../migrations/0018_cmux_vm_domains_tls.sql?raw";
import clientSessionIndex from "../../migrations/0017_cmux_vm_client_session_index.sql?raw";
import agentKeys from "../../migrations/0016_cmux_vm_agent_keys.sql?raw";
import overlayServerCodes from "../../migrations/0015_cmux_vm_overlay_server_codes.sql?raw";
import overlayServers from "../../migrations/0014_cmux_vm_overlay_servers.sql?raw";
import creationReceipts from "../../migrations/0010_cmux_vm_creation_receipts.sql?raw";
import creationReceiptIndex from "../../migrations/0011_cmux_vm_creation_receipt_index.sql?raw";
import overlayPolicy from "../../migrations/0013_cmux_vm_device_overlay_policy.sql?raw";
/**
 * The device address store (bead cx-wb5.45) against migrations 0001-0009 on
 * an in-process Postgres (PGlite): a live device's published public IPv6
 * address, read per mesh by the ACL compiler; the "address" signed-request
 * purpose; and the schema gate naming 0009 when it was not applied.
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
import meshM4 from "../../migrations/0007_cmux_vm_mesh_m4.sql?raw";
import meshM4Retries from "../../migrations/0008_cmux_vm_mesh_m4_retries.sql?raw";
import deviceAddress from "../../migrations/0009_cmux_vm_mesh_device_address.sql?raw";
import uncommittedCreations from "../../migrations/0012_cmux_vm_uncommitted_creations.sql?raw";
import { MeshStore, sqlMeshStoreLayer } from "../../src/db/mesh.ts";
import { checkSchema } from "../../src/db/schema-check.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { newDeviceId, newMeshId, newTunnelId, TenantId } from "../../src/lib/ids.ts";

const BEFORE = [ownership, s2, snapshots, mesh, meshM2, meshM3, meshM4, meshM4Retries];
const ALL = [...BEFORE, deviceAddress, creationReceipts, creationReceiptIndex, uncommittedCreations, overlayPolicy, overlayServers, overlayServerCodes, agentKeys, clientSessionIndex, domainsTls];

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
    for (const migration of [...BEFORE, creationReceipts, creationReceiptIndex, uncommittedCreations, overlayPolicy, overlayServers, overlayServerCodes, agentKeys, clientSessionIndex, domainsTls]) await old.exec(migration);
    expect(await Effect.runPromise(Effect.provide(checkSchema, sqlOver(old)))).toEqual(["cmux_vm.mesh_devices.public_ipv6: missing"]);
  });

  it("refuses a stored address that is not a plain IPv6 literal", async () => {
    const meshId = newMeshId();
    const row = device(meshId, 1);
    await run(Effect.flatMap(MeshStore, (store) => store.recordDevice(T, row)));
    await expect(pg.query("UPDATE cmux_vm.mesh_devices SET public_ipv6 = '2600::1/64' WHERE device_cmux_id = $1", [row.deviceId])).rejects.toThrow();
  });
});

describe("provider-free server storage", () => {
  const row = () => ({ deviceId: newDeviceId(), meshId: newMeshId(), name: "server", wgPublicKey: "public-wg", installPublicKey: "public-install", createdBy: "user:user_ada", createdAt: at(1) });

  it("keeps tenant-scoped identity rows without allocating gateway rows", async () => {
    const server = row();
    expect(await run(Effect.flatMap(MeshStore, (store) => store.recordOverlayServer(T, server)))).toBe(true);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.getOverlayServer(T, server.deviceId)))).toEqual(Option.some(server));
    expect(await run(Effect.flatMap(MeshStore, (store) => store.getOverlayServer(TenantId.make("team_other"), server.deviceId)))).toEqual(Option.none());
    const found = await run(Effect.flatMap(MeshStore, (store) => store.findOverlayServerForSignature(server.deviceId)));
    expect(found).toEqual(Option.some({ ...server, tenantId: T }));
    expect(await run(Effect.flatMap(MeshStore, (store) => store.listDevices(T, server.meshId)))).toEqual([]);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.listOverlayServers(T, server.meshId)))).toEqual([server]);
  });

  it("never overwrites an identity or reuses its tombstone, and confines revocation to the tenant", async () => {
    const server = row();
    const save = (candidate: typeof server) => run(Effect.flatMap(MeshStore, (store) => store.recordOverlayServer(T, candidate)));
    expect(await save(server)).toBe(true);
    expect(await save({ ...server, deviceId: newDeviceId(), name: "replacement" })).toBe(false);
    expect(await save({ ...server, deviceId: newDeviceId(), wgPublicKey: "different" })).toBe(false);
    await run(Effect.flatMap(MeshStore, (store) => store.revokeOverlayServer(TenantId.make("team_other"), server.deviceId, at(2))));
    expect(await run(Effect.flatMap(MeshStore, (store) => store.getOverlayServer(T, server.deviceId)))).toEqual(Option.some(server));
    await run(Effect.flatMap(MeshStore, (store) => store.revokeOverlayServer(T, server.deviceId, at(3))));
    expect(await run(Effect.flatMap(MeshStore, (store) => store.findOverlayServerForSignature(server.deviceId)))).toEqual(Option.none());
    expect(await save(server)).toBe(false);
    const replacement = { ...server, deviceId: newDeviceId() };
    expect(await save(replacement)).toBe(true);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.listOverlayServers(T, server.meshId)))).toEqual([replacement]);
  });

  it("revokes a user's servers by tenant and cutoff, and lists the tenants still holding them", async () => {
    const other = TenantId.make("team_other");
    const old = row();
    const late = { ...row(), createdAt: at(5) };
    const foreign = row();
    const bob = { ...row(), createdBy: "user:user_bob" };
    for (const [tenant, server] of [[T, old], [T, late], [other, foreign], [T, bob]] as const) await run(Effect.flatMap(MeshStore, (store) => store.recordOverlayServer(tenant, server)));
    expect(await run(Effect.flatMap(MeshStore, (store) => store.listTenantsWithOverlayServersCreatedBy("user:user_ada")))).toEqual([T, other]);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.revokeOverlayServersCreatedBy(T, "user:user_ada", at(3), at(6))))).toEqual([old]);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.getOverlayServer(T, late.deviceId)))).toEqual(Option.some(late));
    expect(await run(Effect.flatMap(MeshStore, (store) => store.revokeOverlayServersCreatedBy(other, "user:user_ada", null, at(6))))).toEqual([foreign]);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.revokeOverlayServersCreatedBy(T, "user:user_ada", null, at(7))))).toEqual([late]);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.listTenantsWithOverlayServersCreatedBy("user:user_ada")))).toEqual([]);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.getOverlayServer(T, bob.deviceId)))).toEqual(Option.some(bob));
  });

  it("claims each new signature domain once with old purposes intact", async () => {
    for (const [index, purpose] of ["enroll-overlay-server", "overlay-server-policy", "revoke-overlay-server", "enroll", "overlay-policy"].entries()) {
      const claim = () => run(Effect.flatMap(MeshStore, (store) => store.claimSignedRequest(T, (index + 1).toString(16).repeat(64), purpose, at(120_000), at(0))));
      expect(await claim()).toBe(true); expect(await claim()).toBe(false);
    }
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

  it("accepts distinct overlay replay claims after an idempotent migration, preserving old purposes", async () => {
    await pg.exec(overlayPolicy);
    for (const [index, purpose] of ["enroll", "rotate-key", "peers", "tunnel", "address", "overlay-policy"].entries()) {
      const hash = (index + 1).toString(16).repeat(64);
      const claim = () => run(Effect.flatMap(MeshStore, (store) => store.claimSignedRequest(T, hash, purpose, at(120_000), at(0))));
      expect(await claim()).toBe(true);
      expect(await claim()).toBe(false);
    }
    expect(await Effect.runPromise(Effect.provide(checkSchema, sqlOver(pg)))).toEqual([]);
  });
});

describe("approved server code storage", () => {
  const grant = () => ({ tenantId: T, codeSha256: "e".repeat(64), meshId: newMeshId(), deviceId: newDeviceId(), name: "server", wgPublicKey: "public-wg", installPublicKey: "public-install", createdBy: "user:user_ada", createdAt: at(1), expiresAt: at(600_001), usedAt: null, burnedAt: null });

  it("consumes and registers together, then acknowledges only the exact live reservation", async () => {
    const code = grant();
    await run(Effect.flatMap(MeshStore, (store) => store.insertOverlayServerCode(code)));
    const redeem = () => run(Effect.flatMap(MeshStore, (store) => store.redeemOverlayServerCode(T, code.codeSha256, code.meshId, at(2))));
    expect(await redeem()).toBe(true); expect(await redeem()).toBe(true);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.listOverlayServers(T, code.meshId)))).toEqual([{ deviceId: code.deviceId, meshId: code.meshId, name: code.name, wgPublicKey: code.wgPublicKey, installPublicKey: code.installPublicKey, createdBy: code.createdBy, createdAt: at(2) }]);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.findOverlayServerCode(code.codeSha256)))).toEqual(Option.some({ ...code, usedAt: at(2) }));
    await run(Effect.flatMap(MeshStore, (store) => store.revokeOverlayServer(T, code.deviceId, at(3))));
    expect(await redeem()).toBe(false);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.listOverlayServers(T, code.meshId)))).toEqual([]);
  });

  it("rolls back the identity insert if consumption fails, preserving a usable invitation", async () => {
    const code = grant();
    await run(Effect.flatMap(MeshStore, (store) => store.insertOverlayServerCode(code)));
    await pg.exec("CREATE FUNCTION cmux_vm.fail_code_consumption() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected consumption failure'; END $$; CREATE TRIGGER fail_code_consumption BEFORE UPDATE ON cmux_vm.mesh_overlay_server_codes FOR EACH ROW EXECUTE FUNCTION cmux_vm.fail_code_consumption();");
    const redeem = () => run(Effect.flatMap(MeshStore, (store) => store.redeemOverlayServerCode(T, code.codeSha256, code.meshId, at(2))));
    await expect(redeem()).rejects.toThrow();
    expect(await run(Effect.flatMap(MeshStore, (store) => store.listOverlayServers(T, code.meshId)))).toEqual([]);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.findOverlayServerCode(code.codeSha256)))).toEqual(Option.some(code));
    await pg.exec("DROP TRIGGER fail_code_consumption ON cmux_vm.mesh_overlay_server_codes");
    expect(await redeem()).toBe(true);
  });

  it("isolates tenant, mesh, expiry and burns and does not consume a conflicting reservation", async () => {
    const code = grant();
    await run(Effect.flatMap(MeshStore, (store) => store.insertOverlayServerCode(code)));
    const redeem = (tenant = T, meshId = code.meshId, when = at(2)) => run(Effect.flatMap(MeshStore, (store) => store.redeemOverlayServerCode(tenant, code.codeSha256, meshId, when)));
    expect(await redeem(TenantId.make("team_other"))).toBe(false);
    expect(await redeem(T, newMeshId())).toBe(false);
    expect(await redeem(T, code.meshId, code.expiresAt)).toBe(false);
    await run(Effect.flatMap(MeshStore, (store) => store.recordOverlayServer(T, { ...code, deviceId: newDeviceId() })));
    expect(await redeem()).toBe(false);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.findOverlayServerCode(code.codeSha256)))).toEqual(Option.some(code));
    await run(Effect.flatMap(MeshStore, (store) => store.burnOverlayServerCode(code.codeSha256, at(3))));
    expect(await redeem()).toBe(false);
  });

  it("keeps concurrent codes on one reserved identity and never revives a tombstone", async () => {
    const first = grant(); const second = { ...first, codeSha256: "f".repeat(64) };
    await run(Effect.gen(function* () { const store = yield* MeshStore; yield* store.insertOverlayServerCode(first); yield* store.insertOverlayServerCode(second); }));
    const redeem = (hash: string) => run(Effect.flatMap(MeshStore, (store) => store.redeemOverlayServerCode(T, hash, first.meshId, at(2))));
    expect(await redeem(first.codeSha256)).toBe(true);
    await run(Effect.flatMap(MeshStore, (store) => store.revokeOverlayServer(T, first.deviceId, at(3))));
    expect(await redeem(second.codeSha256)).toBe(false);
    expect(await run(Effect.flatMap(MeshStore, (store) => store.listOverlayServers(T, first.meshId)))).toEqual([]);
  });
});
