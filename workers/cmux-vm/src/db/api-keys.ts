/**
 * API key management on cmux_vm.api_keys (migration 0001). Every statement is
 * keyed by tenant: another tenant's key is indistinguishable from a missing
 * one. Only the SHA-256 hash of a key is ever written; nothing here reads it
 * back.
 */
import { Context, Effect, Layer, Schema } from "effect";
import { ApiKeyId, type TenantId } from "../lib/ids.ts";
import { SqlClient, StoreError } from "./sql.ts";

export interface NewApiKey {
  readonly id: ApiKeyId;
  readonly tenantId: TenantId;
  readonly name: string;
  readonly keyHash: string;
  readonly scopes: ReadonlyArray<string>;
  readonly resourceAllowlist: ReadonlyArray<string> | null;
  readonly createdBy: string;
  readonly createdAt: Date;
  readonly expiresAt: Date | null;
}

/** A key as its tenant's admins see it: no secret, no hash. */
export interface ApiKeyListing {
  readonly id: ApiKeyId;
  readonly name: string;
  readonly scopes: ReadonlyArray<string>;
  readonly resourceAllowlist: ReadonlyArray<string> | null;
  readonly createdBy: string;
  readonly createdAt: Date;
  readonly expiresAt: Date | null;
  readonly revokedAt: Date | null;
}

export interface ApiKeyAdminStoreService {
  readonly insert: (key: NewApiKey) => Effect.Effect<void, StoreError>;
  /** The tenant's keys, newest first, revoked ones included. */
  readonly list: (tenantId: TenantId, limit: number) => Effect.Effect<ReadonlyArray<ApiKeyListing>, StoreError>;
  /** Revokes the tenant's key; false when the tenant has no such key. Revoking twice is not an error. */
  readonly revoke: (tenantId: TenantId, id: ApiKeyId, at: Date) => Effect.Effect<boolean, StoreError>;
}

export class ApiKeyAdminStore extends Context.Tag("cmux-vm/ApiKeyAdminStore")<ApiKeyAdminStore, ApiKeyAdminStoreService>() {}

const words = Schema.NullOr(Schema.String).pipe(
  Schema.transform(Schema.NullOr(Schema.Array(Schema.String)), {
    strict: true,
    decode: (value) => (value === null ? null : value.split(" ").filter((word) => word.length > 0)),
    encode: (value) => (value === null ? null : value.join(" ")),
  }),
);

const When = Schema.Union(Schema.DateFromSelf, Schema.Date);

const Row = Schema.Struct({
  id: ApiKeyId,
  name: Schema.String,
  scopes: words,
  resource_allowlist: words,
  created_by: Schema.String,
  created_at: When,
  expires_at: Schema.NullOr(When),
  revoked_at: Schema.NullOr(When),
});

/** text[] parameters travel as JSON and are unpacked in SQL, since SqlParam has no arrays. */
const textArray = (index: number) => `ARRAY(SELECT jsonb_array_elements_text($${index}::text::jsonb))`;

export const sqlApiKeyAdminStoreLayer: Layer.Layer<ApiKeyAdminStore, never, SqlClient> = Layer.effect(
  ApiKeyAdminStore,
  Effect.map(SqlClient, (sql) => ({
    insert: (key) =>
      sql
        .query(
          "api_keys.insert",
          `INSERT INTO cmux_vm.api_keys
             (id, tenant_id, name, key_hash, scopes, resource_allowlist, created_by, created_at, expires_at)
           VALUES ($1, $2, $3, $4, ${textArray(5)},
                   CASE WHEN $6::text::jsonb IS NULL THEN NULL ELSE ${textArray(6)} END,
                   $7, $8::timestamptz, $9::timestamptz)`,
          [
            key.id,
            key.tenantId,
            key.name,
            key.keyHash,
            JSON.stringify(key.scopes),
            key.resourceAllowlist === null ? null : JSON.stringify(key.resourceAllowlist),
            key.createdBy,
            key.createdAt.toISOString(),
            key.expiresAt === null ? null : key.expiresAt.toISOString(),
          ],
        )
        .pipe(Effect.asVoid),
    list: (tenantId, limit) =>
      sql
        .query(
          "api_keys.list",
          `SELECT id, name,
                  array_to_string(scopes, ' ') AS scopes,
                  CASE WHEN resource_allowlist IS NULL THEN NULL ELSE array_to_string(resource_allowlist, ' ') END AS resource_allowlist,
                  created_by, created_at, expires_at, revoked_at
             FROM cmux_vm.api_keys
            WHERE tenant_id = $1
            ORDER BY created_at DESC, id DESC
            LIMIT $2`,
          [tenantId, limit],
        )
        .pipe(
          Effect.flatMap((rows) =>
            Schema.decodeUnknown(Schema.Array(Row))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation: "api_keys.list", cause }))),
          ),
          Effect.map((rows) =>
            rows.map(
              (row): ApiKeyListing => ({
                id: row.id,
                name: row.name,
                scopes: row.scopes ?? [],
                resourceAllowlist: row.resource_allowlist,
                createdBy: row.created_by,
                createdAt: row.created_at,
                expiresAt: row.expires_at,
                revokedAt: row.revoked_at,
              }),
            ),
          ),
        ),
    revoke: (tenantId, id, at) =>
      sql
        .query(
          "api_keys.revoke",
          `UPDATE cmux_vm.api_keys SET revoked_at = COALESCE(revoked_at, $3::timestamptz)
            WHERE id = $1 AND tenant_id = $2
            RETURNING id`,
          [id, tenantId, at.toISOString()],
        )
        .pipe(Effect.map((rows) => rows.length > 0)),
  })),
);
