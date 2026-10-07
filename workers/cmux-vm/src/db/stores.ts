/**
 * Ownership and API key tables (migrations/). Every ownership read is keyed by
 * tenant: a row that belongs to another tenant is indistinguishable from a row
 * that does not exist.
 */
import { Context, Effect, Layer, Option, Schema } from "effect";
import { ApiKeyId, ResourceKind, TenantId, UpstreamId } from "../lib/ids.ts";
import { SqlClient, StoreError, type SqlParam } from "./sql.ts";

export interface OwnedResource {
  readonly tenantId: TenantId;
  readonly kind: ResourceKind;
  readonly cmuxId: string;
  readonly upstreamId: UpstreamId;
  readonly createdBy: string;
  readonly createdAt: Date;
}

export interface ApiKeyRecord {
  readonly id: ApiKeyId;
  readonly tenantId: TenantId;
  readonly scopes: ReadonlyArray<string>;
  readonly resourceAllowlist: ReadonlyArray<string> | null;
}

export interface OwnershipStoreService {
  /** The caller's own resource of this kind, or none. */
  readonly find: (tenantId: TenantId, kind: ResourceKind, cmuxId: string) => Effect.Effect<Option.Option<OwnedResource>, StoreError>;
  readonly record: (resource: OwnedResource) => Effect.Effect<void, StoreError>;
}

export interface ApiKeyStoreService {
  /** A live (not revoked, not expired at `now`) key with this SHA-256 hex hash, or none. */
  readonly findActiveByHash: (keyHash: string, now: Date) => Effect.Effect<Option.Option<ApiKeyRecord>, StoreError>;
}

export class OwnershipStore extends Context.Tag("cmux-vm/OwnershipStore")<OwnershipStore, OwnershipStoreService>() {}
export class ApiKeyStore extends Context.Tag("cmux-vm/ApiKeyStore")<ApiKeyStore, ApiKeyStoreService>() {}

const words = Schema.NullOr(Schema.String).pipe(
  Schema.transform(Schema.NullOr(Schema.Array(Schema.String)), {
    strict: true,
    decode: (value) => (value === null ? null : value.split(" ").filter((word) => word.length > 0)),
    encode: (value) => (value === null ? null : value.join(" ")),
  }),
);

const ResourceRow = Schema.Struct({
  tenant_id: TenantId,
  kind: ResourceKind,
  cmux_id: Schema.String,
  upstream_id: UpstreamId,
  created_by: Schema.String,
  created_at: Schema.Union(Schema.DateFromSelf, Schema.Date),
});

const ApiKeyRow = Schema.Struct({
  id: ApiKeyId,
  tenant_id: TenantId,
  scopes: words,
  resource_allowlist: words,
});

const decodeRows = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(schema))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));

export const sqlStoresLayer: Layer.Layer<OwnershipStore | ApiKeyStore, never, SqlClient> = Layer.effectContext(
  Effect.gen(function* () {
    const sql = yield* SqlClient;

    const ownership: OwnershipStoreService = {
      find: (tenantId, kind, cmuxId) =>
        sql
          .query(
            "ownership.find",
            `SELECT tenant_id, kind, cmux_id, upstream_id, created_by, created_at
               FROM cmux_vm.resources
              WHERE cmux_id = $1 AND tenant_id = $2 AND kind = $3 AND deleted_at IS NULL
              LIMIT 1`,
            [cmuxId, tenantId, kind],
          )
          .pipe(
            Effect.flatMap(decodeRows(ResourceRow, "ownership.find")),
            Effect.map((rows) =>
              Option.map(Option.fromNullable(rows[0]), (row) => ({
                tenantId: row.tenant_id,
                kind: row.kind,
                cmuxId: row.cmux_id,
                upstreamId: row.upstream_id,
                createdBy: row.created_by,
                createdAt: row.created_at,
              })),
            ),
          ),
      record: (resource) => {
        const params: ReadonlyArray<SqlParam> = [
          resource.cmuxId,
          resource.tenantId,
          resource.kind,
          resource.upstreamId,
          resource.createdBy,
          resource.createdAt.toISOString(),
        ];
        return sql
          .query(
            "ownership.record",
            `INSERT INTO cmux_vm.resources (cmux_id, tenant_id, kind, upstream_id, created_by, created_at)
             VALUES ($1, $2, $3, $4, $5, $6::timestamptz)`,
            params,
          )
          .pipe(Effect.asVoid);
      },
    };

    const apiKeys: ApiKeyStoreService = {
      findActiveByHash: (keyHash, now) =>
        sql
          .query(
            "api_keys.find",
            `SELECT id, tenant_id,
                    array_to_string(scopes, ' ') AS scopes,
                    CASE WHEN resource_allowlist IS NULL THEN NULL
                         ELSE array_to_string(resource_allowlist, ' ') END AS resource_allowlist
               FROM cmux_vm.api_keys
              WHERE key_hash = $1
                AND revoked_at IS NULL
                AND (expires_at IS NULL OR expires_at > $2::timestamptz)
              LIMIT 1`,
            [keyHash, now.toISOString()],
          )
          .pipe(
            Effect.flatMap(decodeRows(ApiKeyRow, "api_keys.find")),
            Effect.map((rows) =>
              Option.map(Option.fromNullable(rows[0]), (row) => ({
                id: row.id,
                tenantId: row.tenant_id,
                scopes: row.scopes ?? [],
                resourceAllowlist: row.resource_allowlist,
              })),
            ),
          ),
    };

    return Context.make(OwnershipStore, ownership).pipe(Context.add(ApiKeyStore, apiKeys));
  }),
);
