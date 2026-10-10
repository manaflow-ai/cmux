/**
 * G1 retries and user.deleted (cx-0op.6) against migrations 0001-0008 on an
 * in-process Postgres (PGlite): the first receipt time of a webhook message
 * (the event time a retry is judged by), revoking a user's cached membership
 * in every tenant, and the tenants where a user has live devices. Also: a
 * database without 0008 refuses the first-receipt record, so the webhook
 * answers 503 and Stack retries.
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
import { MembershipCache } from "../../src/auth/membership-cache.ts";
import { sqlMembershipCacheLayer, sqlWebhookDeliveryStoreLayer, WebhookDeliveryStore } from "../../src/db/identity.ts";
import { MeshStore, sqlMeshStoreLayer } from "../../src/db/mesh.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { newDeviceId, newMeshId, newTunnelId, TenantId, UserId } from "../../src/lib/ids.ts";

type Stores = MembershipCache | WebhookDeliveryStore | MeshStore;

const layerOver = (db: PGlite): Layer.Layer<Stores> => {
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({ try: async () => (await db.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
  });
  return Layer.mergeAll(sqlMembershipCacheLayer, sqlWebhookDeliveryStoreLayer, sqlMeshStoreLayer).pipe(Layer.provide(sql));
};
let pg: PGlite;
let layer: Layer.Layer<Stores>;
const run = <A, E>(effect: Effect.Effect<A, E, Stores>) => Effect.runPromise(Effect.provide(effect, layer));

const A = TenantId.make("team_alpha");
const B = TenantId.make("team_bravo");
const U = UserId.make("user_ada");
const t0 = Date.UTC(2026, 9, 7, 12, 0);
const at = (ms: number) => new Date(t0 + ms);

beforeEach(async () => {
  pg = new PGlite();
  for (const migration of [ownership, s2, snapshots, mesh, meshM2, meshM3, meshM4, meshM4Retries]) await pg.exec(migration);
  layer = layerOver(pg);
});

describe("migration 0008", () => {
  it("is idempotent", async () => {
    await pg.exec(meshM4Retries);
    await pg.exec(meshM4Retries);
  });
});

describe("first receipt of a webhook message", () => {
  const firstSeen = (id: string, when: number) => run(Effect.flatMap(WebhookDeliveryStore, (store) => store.firstSeen(id, at(when))));

  it("keeps the earliest receipt time of a message across retries", async () => {
    expect((await firstSeen("msg_1", 100)).getTime()).toBe(at(100).getTime());
    expect((await firstSeen("msg_1", 5_000)).getTime()).toBe(at(100).getTime());
    // A retry served by an isolate whose clock runs behind still moves it earlier only.
    expect((await firstSeen("msg_1", 50)).getTime()).toBe(at(50).getTime());
    expect((await firstSeen("msg_2", 7_000)).getTime()).toBe(at(7_000).getTime());
  });

  it("fails on a database without 0008", async () => {
    const old = new PGlite();
    for (const migration of [ownership, s2, snapshots, mesh, meshM2, meshM3, meshM4]) await old.exec(migration);
    const attempt = Effect.provide(Effect.flatMap(WebhookDeliveryStore, (store) => store.firstSeen("msg_1", at(0))), layerOver(old));
    await expect(Effect.runPromise(attempt)).rejects.toThrow();
  });
});

describe("revoking a user in every tenant", () => {
  it("hides the user's cached answers in every tenant and refuses older ones, and leaves other users alone", async () => {
    const bob = UserId.make("user_bob");
    await run(
      Effect.gen(function* () {
        const cache = yield* MembershipCache;
        yield* cache.rememberMember(A, U, at(0));
        yield* cache.rememberMember(B, U, at(0));
        yield* cache.rememberMember(A, bob, at(0));
        yield* cache.revokeUser(U, at(10));
        yield* cache.rememberMember(B, U, at(5));
      }),
    );
    const fresh = (tenant: TenantId, user: UserId) => run(Effect.flatMap(MembershipCache, (cache) => cache.fresh(tenant, user, at(-60_000))));
    expect(await fresh(A, U)).toBe(false);
    expect(await fresh(B, U)).toBe(false);
    expect(await fresh(A, bob)).toBe(true);
  });
});

describe("tenants where a user has live devices", () => {
  it("lists each tenant once, only for live devices of exactly that creator", async () => {
    const key = (n: number) => btoa(`device-public-key-${String(n).padStart(14, "0")}`);
    const device = (createdBy: string, n: number) => ({
      deviceId: newDeviceId(),
      meshId: newMeshId(),
      tunnelId: newTunnelId(),
      name: "d",
      wgPublicKey: key(n),
      installPublicKey: null,
      createdBy,
      createdAt: at(n),
    });
    const C = TenantId.make("team_charlie");
    const a1 = device("user:user_ada", 1);
    const a2 = device("user:user_ada", 2);
    const b1 = device("user:user_ada", 3);
    const cGone = device("user:user_ada", 4);
    const cOther = device("user:user_bob", 5);
    await run(
      Effect.gen(function* () {
        const store = yield* MeshStore;
        yield* store.recordDevice(A, a1);
        yield* store.recordDevice(A, a2);
        yield* store.recordDevice(B, b1);
        yield* store.recordDevice(C, cGone);
        yield* store.recordDevice(C, cOther);
        yield* store.markDeviceDeleted(C, cGone.deviceId, at(10));
      }),
    );
    const tenants = await run(Effect.flatMap(MeshStore, (store) => store.listTenantsWithDevicesCreatedBy("user:user_ada")));
    expect([...tenants].sort()).toEqual([A, B].sort());
  });
});
