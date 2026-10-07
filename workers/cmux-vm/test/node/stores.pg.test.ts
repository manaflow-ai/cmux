/**
 * The SQL stores against the real migration on an in-process Postgres
 * (PGlite). No network database is involved.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer, Option } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import migration from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import { hashApiKey, generateApiKey } from "../../src/auth/credentials.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { ApiKeyStore, OwnershipStore, sqlStoresLayer } from "../../src/db/stores.ts";
import { newApiKeyId, newVmId, TenantId, UpstreamId } from "../../src/lib/ids.ts";

let pg: PGlite;
let layer: Layer.Layer<OwnershipStore | ApiKeyStore>;

const run = <A, E>(effect: Effect.Effect<A, E, OwnershipStore | ApiKeyStore>) => Effect.runPromise(Effect.provide(effect, layer));

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
  it("is idempotent and additive", async () => {
    await pg.exec(migration);
    const tables = await pg.query<{ table_name: string }>(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name",
    );
    expect(tables.rows.map((row) => row.table_name)).toEqual(["cmux_vm_api_keys", "cmux_vm_resources"]);
  });

  it("refuses a second claim on the same upstream id and a mismatched id prefix", async () => {
    const insert = "INSERT INTO cmux_vm_resources (cmux_id, tenant_id, kind, upstream_id, created_by) VALUES ($1, $2, $3, $4, 'user:x')";
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
      "INSERT INTO cmux_vm_resources (cmux_id, tenant_id, kind, upstream_id, created_by, deleted_at) VALUES ($1, 'team_a', 'vm', 'vm-up-2', 'user:x', now())",
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
      `INSERT INTO cmux_vm_api_keys (id, tenant_id, name, key_hash, scopes, resource_allowlist, created_by, expires_at, revoked_at)
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
      Option.some({ id, tenantId: "team_a", scopes: ["vm:read", "vm:exec"], resourceAllowlist: [vmId] }),
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
});
