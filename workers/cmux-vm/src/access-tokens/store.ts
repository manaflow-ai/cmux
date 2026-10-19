import { Effect, Layer, Schema } from "effect";
import { AccessTokenId, AccessTokenScope, AccessTokenStore, AccessTokenStoreError, type AccessTokenRecord, type AccessTokenStoreService } from "./tokens.ts";
import { TenantId, UserId, VmId } from "../lib/ids.ts";
import { SqlClient } from "../db/sql.ts";

const DateValue = Schema.Union(Schema.DateFromSelf, Schema.Date);
const Row = Schema.Struct({
  id: AccessTokenId,
  tenant_id: TenantId,
  principal: UserId,
  vm_ids: Schema.Array(VmId),
  scopes: Schema.Array(AccessTokenScope),
  linux_user: Schema.String,
  expires_at: DateValue,
  created_by: Schema.String,
  created_at: DateValue,
  revoked_at: Schema.NullOr(DateValue),
  provider_identity_id: Schema.NullOr(Schema.String),
});

const decode = (operation: string, rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(Row))(rows).pipe(
    Effect.mapError((cause) => new AccessTokenStoreError({ operation, cause })),
    Effect.map((values) => values.map((row): AccessTokenRecord => ({
      id: row.id,
      tenantId: row.tenant_id,
      principal: row.principal,
      vmIds: row.vm_ids,
      scopes: row.scopes,
      linuxUser: row.linux_user,
      expiresAt: row.expires_at,
      createdBy: row.created_by,
      createdAt: row.created_at,
      revokedAt: row.revoked_at,
      providerIdentityId: row.provider_identity_id,
    }))),
  );

const columns = "id, tenant_id, principal, vm_ids, scopes, linux_user, expires_at, created_by, created_at, revoked_at, provider_identity_id";

export const sqlAccessTokenStoreLayer: Layer.Layer<AccessTokenStore, never, SqlClient> = Layer.effect(
  AccessTokenStore,
  Effect.gen(function* () {
    const sql = yield* SqlClient;
    const service: AccessTokenStoreService = {
      insert: (record) =>
        sql.query(
          "access_tokens.insert",
          `INSERT INTO cmux_vm.access_tokens (${columns}) VALUES ($1, $2, $3, $4::text[], $5::text[], $6, $7::timestamptz, $8, $9::timestamptz, NULL, NULL)`,
          [record.id, record.tenantId, record.principal, `{${record.vmIds.join(",")}}`, `{${record.scopes.join(",")}}`, record.linuxUser, record.expiresAt.toISOString(), record.createdBy, record.createdAt.toISOString()],
        ).pipe(Effect.asVoid, Effect.mapError((cause) => new AccessTokenStoreError({ operation: "access_tokens.insert", cause }))),
      find: (tenantId, id) =>
        sql.query("access_tokens.find", `SELECT ${columns} FROM cmux_vm.access_tokens WHERE tenant_id = $1 AND id = $2 LIMIT 1`, [tenantId, id]).pipe(
          Effect.flatMap((rows) => decode("access_tokens.find", rows)),
          Effect.map((rows) => rows[0] ?? null),
        ),
      list: (tenantId, limit) =>
        sql.query("access_tokens.list", `SELECT ${columns} FROM cmux_vm.access_tokens WHERE tenant_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2`, [tenantId, limit]).pipe(
          Effect.flatMap((rows) => decode("access_tokens.list", rows)),
        ),
      revoke: (tenantId, id, at) =>
        sql.query("access_tokens.revoke", `UPDATE cmux_vm.access_tokens SET revoked_at = COALESCE(revoked_at, $3::timestamptz) WHERE tenant_id = $1 AND id = $2 RETURNING ${columns}`, [tenantId, id, at.toISOString()]).pipe(
          Effect.flatMap((rows) => decode("access_tokens.revoke", rows)),
          Effect.map((rows) => rows[0] ?? null),
        ),
      setProviderIdentity: (tenantId, id, identityId) =>
        sql.query("access_tokens.identity", `UPDATE cmux_vm.access_tokens SET provider_identity_id = $3 WHERE tenant_id = $1 AND id = $2`, [tenantId, id, identityId]).pipe(
          Effect.asVoid,
          Effect.mapError((cause) => new AccessTokenStoreError({ operation: "access_tokens.identity", cause })),
        ),
    };
    return service;
  }),
);
