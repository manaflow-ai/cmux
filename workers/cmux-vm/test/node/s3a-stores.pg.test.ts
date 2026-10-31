import agentKeys from "../../migrations/0016_cmux_vm_agent_keys.sql?raw";
/**
 * The snapshot store against migrations 0001, 0002 and 0003
 * on an in-process Postgres (PGlite). No network database is involved.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer, Option } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import s2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import snapshots from "../../migrations/0003_cmux_vm_snapshot_parent.sql?raw";
import uncommittedCreations from "../../migrations/0012_cmux_vm_uncommitted_creations.sql?raw";
import { ApiKeyAdminStore, sqlApiKeyAdminStoreLayer } from "../../src/db/api-keys.ts";
import { sqlSnapshotStoreLayer, SnapshotStore, type SnapshotPage } from "../../src/db/snapshots.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { ApiKeyStore, AuditStore, OwnershipStore, sqlStoresLayer } from "../../src/db/stores.ts";
import { newApiKeyId, newSnapshotId, newVmId, TenantId, UpstreamId } from "../../src/lib/ids.ts";

type Stores = SnapshotStore | OwnershipStore | ApiKeyStore | AuditStore | ApiKeyAdminStore;

let pg: PGlite;
let layer: Layer.Layer<Stores>;

const run = <A, E>(effect: Effect.Effect<A, E, Stores>) => Effect.runPromise(Effect.provide(effect, layer));

const TENANT_A = TenantId.make("team_alpha");
const TENANT_B = TenantId.make("team_bravo");

beforeEach(async () => {
  pg = new PGlite();
  await pg.exec(ownership);
  await pg.exec(s2);
  await pg.exec(snapshots);
  await pg.exec(uncommittedCreations);
  await pg.exec(agentKeys);
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({
        try: async () => (await pg.query(text, [...params])).rows,
        catch: (cause) => new StoreError({ operation, cause }),
      }),
  });
  layer = Layer.mergeAll(sqlSnapshotStoreLayer, sqlStoresLayer, sqlApiKeyAdminStoreLayer).pipe(Layer.provide(sql));
});

const record = (tenantId: TenantId, minute: number, labels: Record<string, string> = {}, sourceVmId = newVmId(), createdBy = "key:test") =>
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
      createdBy,
      createdAt: new Date(Date.UTC(2026, 9, 1, 0, minute)),
    });
    return id;
  });

describe("migration 0003", () => {
  it("is idempotent and additive", async () => {
    await pg.exec(snapshots);
    const tables = await pg.query<{ table_name: string }>(
      "SELECT table_schema || '.' || table_name AS table_name FROM information_schema.tables WHERE table_schema IN ('public', 'cmux_vm') ORDER BY 1",
    );
    expect(tables.rows.map((row) => row.table_name)).toEqual([
      "cmux_vm.api_keys",
      "cmux_vm.audit_log",
      "cmux_vm.resources",
      "cmux_vm.vm_client_sessions",
    ]);
  });
});

describe("snapshot store", () => {
  it("replays the same ownership write and rejects identity changes or resurrection", async () => {
    const value = { tenantId: TENANT_A, id: newSnapshotId(), sourceVmId: newVmId(), upstreamId: UpstreamId.make("sh-capture"),
      createdBy: "service:cloud", displayName: "capture", labels: { role: "cloud" }, createdAt: new Date("2026-10-18T00:00:00Z") };
    const write = (input: typeof value) => run(Effect.flatMap(SnapshotStore, (store) => store.record(input)));
    await write(value); await write(value);
    for (const change of [{ tenantId: TENANT_B }, { upstreamId: UpstreamId.make("sh-different") }, { sourceVmId: newVmId() },
      { createdBy: "service:different" }, { labels: { role: "different" } }, { displayName: "different" }, { createdAt: new Date() }]) {
      await expect(write({ ...value, ...change })).rejects.toThrow();
    }
    await run(Effect.flatMap(SnapshotStore, (store) => store.markDeleted(TENANT_A, value.id, new Date())));
    await expect(write(value)).rejects.toThrow();
    const inspected = await run(Effect.flatMap(SnapshotStore, (store) => store.inspect(TENANT_A, value.id)));
    expect(Option.isSome(inspected) && inspected.value).toMatchObject({ id: value.id, deleted: true, createdBy: "service:cloud" });
    expect(Option.isNone(await run(Effect.flatMap(SnapshotStore, (store) => store.inspect(TENANT_B, value.id))))).toBe(true);
  });

  it("intersects creator, tenant, source, labels, allowlist and deletion before paging", async () => {
    const vm = newVmId();
    const one = await run(record(TENANT_A, 1, { role: "cloud" }, vm, "service:cloud"));
    const two = await run(record(TENANT_A, 2, { role: "cloud" }, vm, "service:cloud"));
    const other = await run(record(TENANT_A, 3, { role: "cloud" }, vm, "key:other"));
    await run(record(TENANT_B, 4, { role: "cloud" }, vm, "service:cloud"));
    await run(record(TENANT_A, 5, { role: "other" }, vm, "service:cloud"));
    await run(record(TENANT_A, 6, { role: "cloud" }, newVmId(), "service:cloud"));
    const deleted = await run(record(TENANT_A, 7, { role: "cloud" }, vm, "service:cloud"));
    await run(Effect.flatMap(SnapshotStore, (store) => store.markDeleted(TENANT_A, deleted, new Date())));
    const base: SnapshotPage = { limit: 1, after: null, sourceVmId: vm, labels: { role: "cloud" }, only: [one, two, other, deleted], createdBy: "service:cloud" };
    const list = (page: SnapshotPage) => run(Effect.flatMap(SnapshotStore, (store) => store.list(TENANT_A, page)));
    const first = await list(base);
    expect(first.map((snapshot) => snapshot.id)).toEqual([two]);
    const last = first[0];
    if (last === undefined) throw new Error("empty creator page");
    expect((await list({ ...base, after: { createdAt: last.createdAt, id: last.id } })).map((snapshot) => snapshot.id)).toEqual([one]);
    expect(await list({ ...base, only: [other, deleted] })).toEqual([]);
    expect(first[0]).not.toHaveProperty("createdBy");
  });

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
    const base = { limit: 10, after: null, sourceVmId: null, labels: null, only: null };

    expect(await list(base)).toEqual([three, two, one]);
    expect(await list({ ...base, limit: 2 })).toEqual([three, two]);
    expect(await list({ ...base, after: { createdAt: new Date(Date.UTC(2026, 9, 1, 0, 2)), id: two } })).toEqual([one]);
    expect(await list({ ...base, sourceVmId: vm })).toEqual([two, one]);
    expect(await list({ ...base, labels: { pool: "x64" } })).toEqual([three, one]);
    expect(await list({ ...base, labels: { pool: "x64", tier: "warm" } })).toEqual([three]);
    expect(await list({ ...base, only: [one, three] })).toEqual([three, one]);
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

describe("API key management store", () => {
  const insert = (tenantId: TenantId, hash: string, allowlist: ReadonlyArray<string> | null = null) =>
    Effect.gen(function* () {
      const store = yield* ApiKeyAdminStore;
      const id = newApiKeyId();
      yield* store.insert({
        id,
        tenantId,
        name: "ci",
        keyHash: hash,
        scopes: ["vm:read", "snapshot:*"],
        resourceAllowlist: allowlist,
        createdBy: "user:test",
        createdAt: new Date(Date.UTC(2026, 9, 1)),
        expiresAt: null,
      });
      return id;
    });

  it("inserts a key the authentication lookup finds, lists it per tenant without the hash, and revokes it per tenant", async () => {
    const hash = "c".repeat(64);
    const vm = newVmId();
    const id = await run(insert(TENANT_A, hash, [vm]));
    const now = new Date(Date.UTC(2026, 9, 2));

    const found = await run(Effect.flatMap(ApiKeyStore, (store) => store.findActiveByHash(hash, now)));
    expect(Option.getOrNull(found)).toMatchObject({ id, tenantId: TENANT_A, scopes: ["vm:read", "snapshot:*"], resourceAllowlist: [vm] });

    const listedA = await run(Effect.flatMap(ApiKeyAdminStore, (store) => store.list(TENANT_A, 10)));
    expect(listedA.map((key) => key.id)).toEqual([id]);
    expect(JSON.stringify(listedA)).not.toContain(hash);
    expect(await run(Effect.flatMap(ApiKeyAdminStore, (store) => store.list(TENANT_B, 10)))).toEqual([]);

    expect(await run(Effect.flatMap(ApiKeyAdminStore, (store) => store.revoke(TENANT_B, id, now)))).toBe(false);
    expect(Option.isSome(await run(Effect.flatMap(ApiKeyStore, (store) => store.findActiveByHash(hash, now))))).toBe(true);
    expect(await run(Effect.flatMap(ApiKeyAdminStore, (store) => store.revoke(TENANT_A, id, now)))).toBe(true);
    expect(Option.isNone(await run(Effect.flatMap(ApiKeyStore, (store) => store.findActiveByHash(hash, now))))).toBe(true);
  });

  it("audits API key ids after migration 0003", async () => {
    const id = newApiKeyId();
    await run(
      Effect.flatMap(AuditStore, (store) =>
        store.append({ tenantId: TENANT_A, actor: "user:test", ownerActor: null, action: "apikey.create", cmuxId: id, outcome: "ok", at: new Date() }),
      ),
    );
    const rows = await pg.query<{ cmux_id: string }>("SELECT cmux_id FROM cmux_vm.audit_log");
    expect(rows.rows).toEqual([{ cmux_id: id }]);
  });
});
