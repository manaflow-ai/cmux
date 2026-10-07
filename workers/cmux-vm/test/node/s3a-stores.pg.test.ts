/**
 * The snapshot, audit and idempotency stores against migrations 0001 and 0002
 * on an in-process Postgres (PGlite). No network database is involved.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer, Option } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import snapshots from "../../migrations/0002_cmux_vm_snapshots_audit_idempotency.sql?raw";
import { AuditLog, sqlAuditLogLayer } from "../../src/db/audit.ts";
import { IdempotencyStore, sqlIdempotencyStoreLayer } from "../../src/db/idempotency.ts";
import { sqlSnapshotStoreLayer, SnapshotStore, type SnapshotPage } from "../../src/db/snapshots.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { OwnershipStore, sqlStoresLayer, type ApiKeyStore } from "../../src/db/stores.ts";
import { newSnapshotId, newVmId, TenantId, UpstreamId } from "../../src/lib/ids.ts";

type Stores = SnapshotStore | AuditLog | IdempotencyStore | OwnershipStore | ApiKeyStore;

let pg: PGlite;
let layer: Layer.Layer<Stores>;

const run = <A, E>(effect: Effect.Effect<A, E, Stores>) => Effect.runPromise(Effect.provide(effect, layer));

const TENANT_A = TenantId.make("team_alpha");
const TENANT_B = TenantId.make("team_bravo");

beforeEach(async () => {
  pg = new PGlite();
  await pg.exec(ownership);
  await pg.exec(snapshots);
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({
        try: async () => (await pg.query(text, [...params])).rows,
        catch: (cause) => new StoreError({ operation, cause }),
      }),
  });
  layer = Layer.mergeAll(sqlSnapshotStoreLayer, sqlAuditLogLayer, sqlIdempotencyStoreLayer, sqlStoresLayer).pipe(Layer.provide(sql));
});

const record = (tenantId: TenantId, minute: number, labels: Record<string, string> = {}, sourceVmId = newVmId()) =>
  Effect.gen(function* () {
    const store = yield* SnapshotStore;
    const id = newSnapshotId();
    yield* store.record({
      tenantId,
      id,
      upstreamId: UpstreamId.make(`sc-${crypto.randomUUID()}`),
      sourceVmId,
      displayName: `snap ${minute}`,
      labels,
      createdBy: "key:test",
      createdAt: new Date(Date.UTC(2026, 9, 1, 0, minute)),
    });
    return id;
  });

describe("migration 0002", () => {
  it("is idempotent and additive", async () => {
    await pg.exec(snapshots);
    const tables = await pg.query<{ table_name: string }>(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name",
    );
    expect(tables.rows.map((row) => row.table_name)).toEqual([
      "cmux_vm_api_keys",
      "cmux_vm_audit_log",
      "cmux_vm_idempotency_keys",
      "cmux_vm_resources",
    ]);
  });
});

describe("snapshot store", () => {
  it("records rows the ownership store resolves for the owner only", async () => {
    const id = await run(record(TENANT_A, 1));
    const own = await run(Effect.flatMap(OwnershipStore, (store) => store.find(TENANT_A, "snapshot", id)));
    const other = await run(Effect.flatMap(OwnershipStore, (store) => store.find(TENANT_B, "snapshot", id)));
    expect(Option.isSome(own)).toBe(true);
    expect(Option.isNone(other)).toBe(true);
    expect(Option.isNone(await run(Effect.flatMap(SnapshotStore, (store) => store.describe(TENANT_B, id))))).toBe(true);
  });

  it("lists newest first per tenant with keyset pages, source and label filters", async () => {
    const vm = newVmId();
    const one = await run(record(TENANT_A, 1, { pool: "x64" }, vm));
    const two = await run(record(TENANT_A, 2, { pool: "arm" }, vm));
    const three = await run(record(TENANT_A, 3, { pool: "x64", tier: "warm" }));
    await run(record(TENANT_B, 4, { pool: "x64" }));

    const list = (page: SnapshotPage) =>
      run(Effect.flatMap(SnapshotStore, (store) => store.list(TENANT_A, page))).then((rows) => rows.map((row) => row.id));
    const base = { limit: 10, after: null, sourceVmId: null, labels: null };

    expect(await list(base)).toEqual([three, two, one]);
    expect(await list({ ...base, limit: 2 })).toEqual([three, two]);
    expect(await list({ ...base, after: { createdAt: new Date(Date.UTC(2026, 9, 1, 0, 2)), id: two } })).toEqual([one]);
    expect(await list({ ...base, sourceVmId: vm })).toEqual([two, one]);
    expect(await list({ ...base, labels: { pool: "x64" } })).toEqual([three, one]);
    expect(await list({ ...base, labels: { pool: "x64", tier: "warm" } })).toEqual([three]);
  });

  it("marks only the owner's row deleted", async () => {
    const id = await run(record(TENANT_A, 1));
    const at = new Date();
    await run(Effect.flatMap(SnapshotStore, (store) => store.markDeleted(TENANT_B, id, at)));
    expect(Option.isSome(await run(Effect.flatMap(SnapshotStore, (store) => store.describe(TENANT_A, id))))).toBe(true);
    await run(Effect.flatMap(SnapshotStore, (store) => store.markDeleted(TENANT_A, id, at)));
    expect(Option.isNone(await run(Effect.flatMap(SnapshotStore, (store) => store.describe(TENANT_A, id))))).toBe(true);
  });
});

describe("idempotency store", () => {
  const fingerprint = "a".repeat(64);
  const other = "b".repeat(64);
  const claim = (tenant: TenantId, key: string, print: string, now = new Date(Date.UTC(2026, 9, 1))) =>
    run(Effect.flatMap(IdempotencyStore, (store) => store.claim(tenant, key, print, now)));

  it("starts, reports in progress, replays, rejects a different request, and is per tenant", async () => {
    expect(await claim(TENANT_A, "k", fingerprint)).toEqual({ _tag: "Started" });
    expect(await claim(TENANT_A, "k", fingerprint)).toEqual({ _tag: "InProgress" });
    await run(Effect.flatMap(IdempotencyStore, (store) => store.complete(TENANT_A, "k", fingerprint, '{"id":"x"}')));
    expect(await claim(TENANT_A, "k", fingerprint)).toEqual({ _tag: "Replay", body: '{"id":"x"}' });
    expect(await claim(TENANT_A, "k", other)).toEqual({ _tag: "Mismatch" });
    expect(await claim(TENANT_B, "k", other)).toEqual({ _tag: "Started" });
  });

  it("releases a failed claim and replaces an expired one", async () => {
    expect(await claim(TENANT_A, "k", fingerprint)).toEqual({ _tag: "Started" });
    await run(Effect.flatMap(IdempotencyStore, (store) => store.release(TENANT_A, "k", fingerprint)));
    expect(await claim(TENANT_A, "k", other)).toEqual({ _tag: "Started" });
    expect(await claim(TENANT_A, "k", fingerprint, new Date(Date.UTC(2026, 9, 3)))).toEqual({ _tag: "Started" });
  });
});

describe("audit log", () => {
  it("stores one row per entry and rejects ids that are not public ids", async () => {
    const id = newSnapshotId();
    await run(
      Effect.flatMap(AuditLog, (log) =>
        log.record({ tenantId: TENANT_A, actor: "key:vmk_x", action: "snapshot.create", resourceId: id, outcome: "succeeded", at: new Date() }),
      ),
    );
    const rows = await pg.query<{ resource_id: string; action: string }>("SELECT resource_id, action FROM cmux_vm_audit_log");
    expect(rows.rows).toEqual([{ resource_id: id, action: "snapshot.create" }]);
    const leaked = Effect.flatMap(AuditLog, (log) =>
      log.record({ tenantId: TENANT_A, actor: "key:vmk_x", action: "snapshot.create", resourceId: "sc-upstream", outcome: "failed", at: new Date() }),
    );
    await expect(run(leaked)).rejects.toThrow();
  });
});
