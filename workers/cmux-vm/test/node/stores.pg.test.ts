/**
 * The SQL stores against the real migration on an in-process Postgres
 * (PGlite). No network database is involved.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer, Option } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import migration1 from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import migration2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import { hashApiKey, generateApiKey } from "../../src/auth/credentials.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { ApiKeyStore, AuditStore, OwnershipStore, sqlStoresLayer, type OwnedResource } from "../../src/db/stores.ts";
import { newApiKeyId, newVmId, TenantId, UpstreamId } from "../../src/lib/ids.ts";

let pg: PGlite;
let layer: Layer.Layer<OwnershipStore | ApiKeyStore | AuditStore>;

const migration = `${migration1}\n${migration2}`;

const run = <A, E>(effect: Effect.Effect<A, E, OwnershipStore | ApiKeyStore | AuditStore>) => Effect.runPromise(Effect.provide(effect, layer));

beforeEach(async () => {
  pg = new PGlite();
  await pg.exec(migration);
  layer = sqlStoresLayer.pipe(
    Layer.provide(
      Layer.succeed(SqlClient, {
        query: (operation, text, params) =>
          Effect.tryPromise({
            try: async () => (await pg.query(text, [...params])).rows,
            catch: (cause) => new StoreError({ operation, cause }),
          }),
      }),
    ),
  );
});

describe("migration", () => {
  it("is idempotent and creates nothing outside the cmux_vm schema", async () => {
    await pg.exec(migration);
    const tables = await pg.query<{ name: string }>(
      `SELECT table_schema || '.' || table_name AS name FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY name`,
    );
    expect(tables.rows.map((row) => row.name)).toEqual(["cmux_vm.api_keys", "cmux_vm.audit_log", "cmux_vm.resources"]);
    const indexes = await pg.query<{ name: string }>(
      `SELECT schemaname || '.' || indexname AS name FROM pg_indexes
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY name`,
    );
    expect(indexes.rows.map((row) => row.name)).toEqual([
      "cmux_vm.api_keys_key_hash_key",
      "cmux_vm.api_keys_pkey",
      "cmux_vm.api_keys_tenant_idx",
      "cmux_vm.audit_log_pkey",
      "cmux_vm.audit_log_tenant_created_idx",
      "cmux_vm.resources_kind_upstream_key",
      "cmux_vm.resources_pkey",
      "cmux_vm.resources_tenant_kind_created_idx",
    ]);
  });

  it("refuses a second claim on the same upstream id and a mismatched id prefix", async () => {
    const insert = "INSERT INTO cmux_vm.resources (cmux_id, tenant_id, kind, upstream_id, created_by) VALUES ($1, $2, $3, $4, 'user:x')";
    await pg.query(insert, [newVmId(), "team_a", "vm", "vm-upstream-1"]);
    await expect(pg.query(insert, [newVmId(), "team_b", "vm", "vm-upstream-1"])).rejects.toThrow();
    await expect(pg.query(insert, [newVmId(), "team_b", "snapshot", "sc-1"])).rejects.toThrow();
  });
});

describe("ownership store", () => {
  it("finds a resource only for its own tenant", async () => {
    const vmId = newVmId();
    await run(
      Effect.flatMap(OwnershipStore, (store) =>
        store.record({
          tenantId: TenantId.make("team_a"),
          kind: "vm",
          cmuxId: vmId,
          upstreamId: UpstreamId.make("vm-upstream-1"),
          createdBy: "user:alice",
          createdAt: new Date("2026-10-01T00:00:00Z"),
          displayName: null,
          labels: {},
        }),
      ),
    );
    const own = await run(Effect.flatMap(OwnershipStore, (store) => store.find(TenantId.make("team_a"), "vm", vmId)));
    const other = await run(Effect.flatMap(OwnershipStore, (store) => store.find(TenantId.make("team_b"), "vm", vmId)));
    const wrongKind = await run(Effect.flatMap(OwnershipStore, (store) => store.find(TenantId.make("team_a"), "snapshot", vmId)));
    expect(Option.map(own, (row) => row.upstreamId)).toEqual(Option.some("vm-upstream-1"));
    expect(Option.isNone(other)).toBe(true);
    expect(Option.isNone(wrongKind)).toBe(true);
  });

  it("hides soft-deleted resources", async () => {
    const vmId = newVmId();
    await pg.query(
      "INSERT INTO cmux_vm.resources (cmux_id, tenant_id, kind, upstream_id, created_by, deleted_at) VALUES ($1, 'team_a', 'vm', 'vm-up-2', 'user:x', now())",
      [vmId],
    );
    const found = await run(Effect.flatMap(OwnershipStore, (store) => store.find(TenantId.make("team_a"), "vm", vmId)));
    expect(Option.isNone(found)).toBe(true);
  });
});

describe("api key store", () => {
  const insertKey = async (options: { scopes: string[]; allowlist?: string[]; revoked?: boolean; expiresAt?: string }) => {
    const secret = generateApiKey();
    const hash = await Effect.runPromise(hashApiKey(secret));
    const id = newApiKeyId();
    await pg.query(
      `INSERT INTO cmux_vm.api_keys (id, tenant_id, name, key_hash, scopes, resource_allowlist, created_by, expires_at, revoked_at)
       VALUES ($1, 'team_a', 'ci', $2, $3, $4, 'user:alice', $5::timestamptz, CASE WHEN $6 THEN now() ELSE NULL END)`,
      [id, hash, options.scopes, options.allowlist ?? null, options.expiresAt ?? null, options.revoked ?? false],
    );
    return { id, hash };
  };
  const now = new Date("2026-10-07T00:00:00Z");

  it("finds a live key by hash with its scopes and allowlist", async () => {
    const vmId = newVmId();
    const { id, hash } = await insertKey({ scopes: ["vm:read", "vm:exec"], allowlist: [vmId] });
    const found = await run(Effect.flatMap(ApiKeyStore, (store) => store.findActiveByHash(hash, now)));
    expect(found).toEqual(
      Option.some({ id, tenantId: "team_a", scopes: ["vm:read", "vm:exec"], resourceAllowlist: [vmId], expiresAt: null }),
    );
  });

  it("returns a null allowlist when the key is unrestricted", async () => {
    const { hash } = await insertKey({ scopes: ["vm:read"] });
    const found = await run(Effect.flatMap(ApiKeyStore, (store) => store.findActiveByHash(hash, now)));
    expect(Option.map(found, (key) => key.resourceAllowlist)).toEqual(Option.some(null));
  });

  it("ignores revoked and expired keys", async () => {
    const revoked = await insertKey({ scopes: ["vm:read"], revoked: true });
    const expired = await insertKey({ scopes: ["vm:read"], expiresAt: "2026-10-06T00:00:00Z" });
    const future = await insertKey({ scopes: ["vm:read"], expiresAt: "2026-10-08T00:00:00Z" });
    const find = (hash: string) => run(Effect.flatMap(ApiKeyStore, (store) => store.findActiveByHash(hash, now)));
    expect(Option.isNone(await find(revoked.hash))).toBe(true);
    expect(Option.isNone(await find(expired.hash))).toBe(true);
    expect(Option.isSome(await find(future.hash))).toBe(true);
  });

  it("finds a live key by tenant and id, and ignores revoked, expired and other tenants' keys (M3 code and device checks)", async () => {
    const live = await insertKey({ scopes: ["mesh:join"] });
    const revoked = await insertKey({ scopes: ["mesh:join"], revoked: true });
    const expired = await insertKey({ scopes: ["mesh:join"], expiresAt: "2026-10-06T00:00:00Z" });
    const find = (tenant: string, id: typeof live.id) => run(Effect.flatMap(ApiKeyStore, (store) => store.findActiveById(TenantId.make(tenant), id, now)));
    expect(Option.map(await find("team_a", live.id), (key) => [key.id, key.tenantId])).toEqual(Option.some([live.id, "team_a"]));
    expect(Option.isNone(await find("team_b", live.id))).toBe(true);
    expect(Option.isNone(await find("team_a", revoked.id))).toBe(true);
    expect(Option.isNone(await find("team_a", expired.id))).toBe(true);
  });
});

describe("S2 ownership queries", () => {
  const tenantA = TenantId.make("team_a");
  const row = (overrides: Partial<OwnedResource> & { readonly cmuxId: string; readonly createdAt: Date }): OwnedResource => ({
    tenantId: tenantA,
    kind: "vm",
    upstreamId: UpstreamId.make(`vm-${overrides.cmuxId}`),
    createdBy: "key:vmk_x",
    displayName: null,
    labels: {},
    ...overrides,
  });
  const record = (resource: OwnedResource) => run(Effect.flatMap(OwnershipStore, (store) => store.record(resource)));

  it("pages newest first by keyset, counts live rows and hides deleted ones", async () => {
    const ids = [newVmId(), newVmId(), newVmId()];
    for (const [index, cmuxId] of ids.entries()) {
      await record(row({ cmuxId, createdAt: new Date(Date.UTC(2026, 9, 1, 0, index)), displayName: `box ${index}` }));
    }
    await record(row({ cmuxId: newVmId(), createdAt: new Date("2026-10-02T00:00:00Z"), tenantId: TenantId.make("team_b") }));

    const page1 = await run(Effect.flatMap(OwnershipStore, (store) => store.listPage(tenantA, "vm", { limit: 2, after: null, only: null, labels: null })));
    expect(page1.map((found) => found.cmuxId)).toEqual([ids[2], ids[1]]);
    expect(page1[0]?.displayName).toBe("box 2");
    const last = page1.at(-1);
    if (last === undefined) throw new Error("empty page");
    const page2 = await run(
      Effect.flatMap(OwnershipStore, (store) =>
        store.listPage(tenantA, "vm", { limit: 2, after: { createdAt: last.createdAt, cmuxId: last.cmuxId }, only: null, labels: null }),
      ),
    );
    expect(page2.map((found) => found.cmuxId)).toEqual([ids[0]]);

    expect(await run(Effect.flatMap(OwnershipStore, (store) => store.countLive(tenantA, "vm")))).toBe(3);
    await run(Effect.flatMap(OwnershipStore, (store) => store.markDeleted(TenantId.make("team_b"), "vm", ids[0] ?? "", new Date())));
    expect(await run(Effect.flatMap(OwnershipStore, (store) => store.countLive(tenantA, "vm")))).toBe(3);
    await run(Effect.flatMap(OwnershipStore, (store) => store.markDeleted(tenantA, "vm", ids[0] ?? "", new Date())));
    expect(await run(Effect.flatMap(OwnershipStore, (store) => store.countLive(tenantA, "vm")))).toBe(2);
    const found = await run(Effect.flatMap(OwnershipStore, (store) => store.find(tenantA, "vm", ids[0] ?? "")));
    expect(Option.isNone(found)).toBe(true);
  });

  it("filters by allowlist and labels", async () => {
    const ci = newVmId();
    const dev = newVmId();
    await record(row({ cmuxId: ci, createdAt: new Date("2026-10-01T00:00:00Z"), labels: { role: "ci", "actions/run": "42" } }));
    await record(row({ cmuxId: dev, createdAt: new Date("2026-10-01T00:01:00Z"), labels: { role: "dev" } }));

    const list = (options: { only: ReadonlySet<string> | null; labels: Readonly<Record<string, string>> | null }) =>
      run(Effect.flatMap(OwnershipStore, (store) => store.listPage(tenantA, "vm", { limit: 10, after: null, ...options })));

    expect((await list({ only: null, labels: { role: "ci" } })).map((found) => found.cmuxId)).toEqual([ci]);
    expect((await list({ only: null, labels: { role: "ci", "actions/run": "42" } })).map((found) => found.labels)).toEqual([
      { role: "ci", "actions/run": "42" },
    ]);
    expect((await list({ only: new Set([dev]), labels: null })).map((found) => found.cmuxId)).toEqual([dev]);
    expect(await list({ only: new Set([dev]), labels: { role: "ci" } })).toEqual([]);
  });

  it("appends audit rows and refuses free text in their id column", async () => {
    const vmId = newVmId();
    await run(
      Effect.flatMap(AuditStore, (store) =>
        store.append({ tenantId: tenantA, actor: "key:vmk_x", ownerActor: null, action: "vm.exec", cmuxId: vmId, outcome: "ok", at: new Date() }),
      ),
    );
    const rows = await pg.query<{ action: string; cmux_id: string }>("SELECT action, cmux_id FROM cmux_vm.audit_log");
    expect(rows.rows).toEqual([{ action: "vm.exec", cmux_id: vmId }]);
    await expect(
      run(
        Effect.flatMap(AuditStore, (store) =>
          store.append({ tenantId: tenantA, actor: "key:vmk_x", ownerActor: null, action: "vm.exec", cmuxId: "rm -rf /", outcome: "ok", at: new Date() }),
        ),
      ),
    ).rejects.toThrow();
  });
});
