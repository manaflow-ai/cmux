/**
 * Mesh M4 stores against migrations 0001-0007 on an in-process Postgres
 * (PGlite): the shared membership cache, webhook deliveries, owned audit rows
 * and the devices of one creator. Also: rows without an owner are still
 * written by a database without 0007 (the Worker may deploy before it).
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
import { MembershipCache } from "../../src/auth/membership-cache.ts";
import { sqlMembershipCacheLayer, sqlWebhookDeliveryStoreLayer, WebhookDeliveryStore } from "../../src/db/identity.ts";
import { MeshStore, sqlMeshStoreLayer } from "../../src/db/mesh.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { AuditStore, sqlStoresLayer } from "../../src/db/stores.ts";
import { newDeviceId, newMeshId, newTunnelId, TenantId, UserId } from "../../src/lib/ids.ts";

type Stores = MembershipCache | WebhookDeliveryStore | MeshStore | AuditStore;

let pg: PGlite;
const layerOver = (db: PGlite): Layer.Layer<Stores> => {
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({ try: async () => (await db.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
  });
  return Layer.mergeAll(sqlMembershipCacheLayer, sqlWebhookDeliveryStoreLayer, sqlMeshStoreLayer, sqlStoresLayer).pipe(Layer.provide(sql));
};
let layer: Layer.Layer<Stores>;
const run = <A, E>(effect: Effect.Effect<A, E, Stores>) => Effect.runPromise(Effect.provide(effect, layer));

const T = TenantId.make("team_alpha");
const U = UserId.make("user_ada");
const t0 = Date.UTC(2026, 9, 7, 12, 0);
const at = (ms: number) => new Date(t0 + ms);

beforeEach(async () => {
  pg = new PGlite();
  for (const migration of [ownership, s2, snapshots, mesh, meshM2, meshM3, meshM4]) await pg.exec(migration);
  layer = layerOver(pg);
});

describe("migration 0007", () => {
  it("is idempotent", async () => {
    await pg.exec(meshM4);
    await pg.exec(meshM4);
  });

  it("accepts the audit action device.rotate_key, which 0002's CHECK refused", async () => {
    await run(
      Effect.flatMap(AuditStore, (audit) =>
        audit.append({ tenantId: T, actor: "user:user_ada", ownerActor: null, action: "device.rotate_key", cmuxId: null, outcome: "ok", at: at(0) }),
      ),
    );
    await expect(pg.query("INSERT INTO cmux_vm.audit_log (tenant_id, actor, action, outcome) VALUES ('t', 'a', 'Bad-Action', 'ok')")).rejects.toThrow();
  });
});

describe("shared membership cache", () => {
  const fresh = (since: number) => run(Effect.flatMap(MembershipCache, (cache) => cache.fresh(T, U, at(since))));
  const remember = (asked: number) => run(Effect.flatMap(MembershipCache, (cache) => cache.rememberMember(T, U, at(asked))));
  const revoke = (when: number) => run(Effect.flatMap(MembershipCache, (cache) => cache.revoke(T, U, at(when))));

  it("holds a positive answer until it is older than the window", async () => {
    expect(await fresh(-60_000)).toBe(false);
    await remember(0);
    expect(await fresh(-60_000)).toBe(true);
    expect(await fresh(0)).toBe(false);
  });

  it("a revocation hides older answers and refuses to store one asked before it", async () => {
    await remember(0);
    await revoke(10);
    expect(await fresh(-60_000)).toBe(false);
    await remember(5);
    expect(await fresh(-60_000)).toBe(false);
    await remember(10);
    expect(await fresh(-60_000)).toBe(false);
    await remember(20);
    expect(await fresh(-60_000)).toBe(true);
    // An older revocation retried later does not move the revocation back.
    await revoke(1);
    expect(await fresh(-60_000)).toBe(true);
  });
});

describe("webhook deliveries", () => {
  it("records a message once and reports it processed", async () => {
    const delivery = { messageId: "msg_1", eventType: "team_membership.deleted", tenantId: T, userId: U, processedAt: at(0) };
    expect(await run(Effect.flatMap(WebhookDeliveryStore, (store) => store.processed("msg_1")))).toBe(false);
    await run(Effect.flatMap(WebhookDeliveryStore, (store) => store.record(delivery)));
    await run(Effect.flatMap(WebhookDeliveryStore, (store) => store.record(delivery)));
    expect(await run(Effect.flatMap(WebhookDeliveryStore, (store) => store.processed("msg_1")))).toBe(true);
  });
});

describe("audit rows with an owner", () => {
  it("stores the device actor and its owner", async () => {
    const deviceId = newDeviceId();
    await run(
      Effect.flatMap(AuditStore, (audit) =>
        audit.append({ tenantId: T, actor: `device:${deviceId}`, ownerActor: "user:user_ada", action: "device.rotate_key", cmuxId: deviceId, outcome: "ok", at: at(0) }),
      ),
    );
    const rows = (await pg.query("SELECT actor, owner_actor FROM cmux_vm.audit_log")).rows;
    expect(rows).toEqual([{ actor: `device:${deviceId}`, owner_actor: "user:user_ada" }]);
  });

  it("rows without an owner are written by a database without 0007", async () => {
    const old = new PGlite();
    for (const migration of [ownership, s2, snapshots, mesh, meshM2, meshM3]) await old.exec(migration);
    await Effect.runPromise(
      Effect.provide(
        Effect.flatMap(AuditStore, (audit) => audit.append({ tenantId: T, actor: "user:user_ada", ownerActor: null, action: "mesh.create", cmuxId: null, outcome: "ok", at: at(0) })),
        layerOver(old),
      ),
    );
    expect((await old.query("SELECT count(*)::int AS n FROM cmux_vm.audit_log")).rows).toEqual([{ n: 1 }]);
  });
});

describe("devices of one creator", () => {
  it("lists the creator's live devices in every mesh of the tenant only", async () => {
    const key = (n: number) => btoa(`device-public-key-${String(n).padStart(14, "0")}`);
    const device = (meshId: string, createdBy: string, n: number) => ({
      deviceId: newDeviceId(),
      meshId,
      tunnelId: newTunnelId(),
      name: "d",
      wgPublicKey: key(n),
      installPublicKey: null,
      createdBy,
      createdAt: at(n),
    });
    const m1 = newMeshId();
    const m2 = newMeshId();
    const mine1 = device(m1, "user:user_ada", 1);
    const mine2 = device(m2, "user:user_ada", 2);
    const gone = device(m1, "user:user_ada", 3);
    const other = device(m1, "user:user_bob", 4);
    const otherTenant = device(m1, "user:user_ada", 5);
    await run(
      Effect.gen(function* () {
        const store = yield* MeshStore;
        for (const row of [mine1, mine2, gone, other]) yield* store.recordDevice(T, row);
        yield* store.recordDevice(TenantId.make("team_bravo"), otherTenant);
        yield* store.markDeviceDeleted(T, gone.deviceId, at(10));
      }),
    );
    const listed = await run(Effect.flatMap(MeshStore, (store) => store.listDevicesCreatedBy(T, "user:user_ada")));
    expect(listed.map((row) => row.deviceId)).toEqual([mine1.deviceId, mine2.deviceId]);
  });
});
