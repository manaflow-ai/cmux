import { Context, Effect, Layer, Option, Schema } from "effect";
import { IdentityId, TenantId, UpstreamId, VmId } from "../lib/ids.ts";
import { SqlClient, StoreError } from "../db/sql.ts";

export interface IdentityRecord {
  readonly tenantId: TenantId;
  readonly cmuxId: IdentityId;
  readonly upstreamId: UpstreamId;
  readonly managed: boolean;
  readonly createdAt: Date;
}

export interface IdentityGrant {
  readonly id: string;
  readonly tenantId: TenantId;
  readonly identityCmuxId: IdentityId;
  readonly vmCmuxId: VmId;
  readonly upstreamId: UpstreamId;
  readonly allowedLinuxUsers: ReadonlyArray<string> | null;
  readonly grantedAt: Date;
  readonly grantedBy: string;
}

export interface IdentityToken {
  readonly id: string;
  readonly tenantId: TenantId;
  readonly identityCmuxId: IdentityId;
  readonly tokenHash: string;
  readonly createdAt: Date;
}

export interface IdentityStoreService {
  readonly recordIdentity: (identity: IdentityRecord) => Effect.Effect<void, StoreError>;
  readonly listIdentities: (tenantId: TenantId) => Effect.Effect<ReadonlyArray<IdentityRecord>, StoreError>;
  readonly markIdentityDeleted: (tenantId: TenantId, id: IdentityId, at: Date) => Effect.Effect<void, StoreError>;
  readonly recordGrant: (grant: IdentityGrant) => Effect.Effect<void, StoreError>;
  readonly listGrants: (tenantId: TenantId, identityId: IdentityId) => Effect.Effect<ReadonlyArray<IdentityGrant>, StoreError>;
  readonly findGrant: (tenantId: TenantId, identityId: IdentityId, vmId: VmId) => Effect.Effect<Option.Option<IdentityGrant>, StoreError>;
  readonly revokeGrant: (tenantId: TenantId, identityId: IdentityId, vmId: VmId, at: Date) => Effect.Effect<void, StoreError>;
  readonly revokeGrantsForVm: (tenantId: TenantId, vmId: VmId, at: Date) => Effect.Effect<void, StoreError>;
  readonly recordToken: (token: IdentityToken) => Effect.Effect<void, StoreError>;
  readonly listTokens: (tenantId: TenantId, identityId: IdentityId) => Effect.Effect<ReadonlyArray<IdentityToken>, StoreError>;
  readonly revokeToken: (tenantId: TenantId, identityId: IdentityId, tokenId: string, at: Date) => Effect.Effect<void, StoreError>;
  readonly findToken: (tokenHash: string) => Effect.Effect<Option.Option<IdentityToken>, StoreError>;
}

export class IdentityStore extends Context.Tag("cmux-vm/IdentityStore")<IdentityStore, IdentityStoreService>() {}

const IdentityRow = Schema.Struct({
  tenant_id: TenantId,
  cmux_id: IdentityId,
  upstream_id: UpstreamId,
  managed: Schema.Boolean,
  created_at: Schema.Union(Schema.DateFromSelf, Schema.Date),
});
const GrantRow = Schema.Struct({
  id: Schema.String,
  tenant_id: TenantId,
  identity_cmux_id: IdentityId,
  vm_cmux_id: VmId,
  upstream_id: UpstreamId,
  allowed_linux_users: Schema.NullOr(Schema.Array(Schema.String)),
  granted_at: Schema.Union(Schema.DateFromSelf, Schema.Date),
  granted_by: Schema.String,
});
const TokenRow = Schema.Struct({
  id: Schema.String,
  tenant_id: TenantId,
  identity_cmux_id: IdentityId,
  token_hash: Schema.String,
  created_at: Schema.Union(Schema.DateFromSelf, Schema.Date),
});
const decode = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(schema))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));
const identityOf = (row: typeof IdentityRow.Type): IdentityRecord => ({ tenantId: row.tenant_id, cmuxId: row.cmux_id, upstreamId: row.upstream_id, managed: row.managed, createdAt: row.created_at });
const grantOf = (row: typeof GrantRow.Type): IdentityGrant => ({ id: row.id, tenantId: row.tenant_id, identityCmuxId: row.identity_cmux_id, vmCmuxId: row.vm_cmux_id, upstreamId: row.upstream_id, allowedLinuxUsers: row.allowed_linux_users, grantedAt: row.granted_at, grantedBy: row.granted_by });
const tokenOf = (row: typeof TokenRow.Type): IdentityToken => ({ id: row.id, tenantId: row.tenant_id, identityCmuxId: row.identity_cmux_id, tokenHash: row.token_hash, createdAt: row.created_at });

export const sqlIdentityStoreLayer: Layer.Layer<IdentityStore, never, SqlClient> = Layer.effect(
  IdentityStore,
  Effect.gen(function* () {
    const sql = yield* SqlClient;
    return {
      recordIdentity: (_identity) => Effect.void,
      listIdentities: (tenantId) =>
        sql.query("identities.list", `SELECT tenant_id, cmux_id, upstream_id, true AS managed, created_at FROM cmux_vm.resources WHERE tenant_id = $1 AND kind = 'identity' AND deleted_at IS NULL ORDER BY created_at DESC`, [tenantId]).pipe(Effect.flatMap(decode(IdentityRow, "identities.list")), Effect.map((rows) => rows.map(identityOf))),
      markIdentityDeleted: (tenantId, id, at) => sql.query("identities.delete", `UPDATE cmux_vm.resources SET deleted_at = $3::timestamptz WHERE tenant_id = $1 AND cmux_id = $2 AND kind = 'identity' AND deleted_at IS NULL`, [tenantId, id, at.toISOString()]).pipe(Effect.asVoid),
      recordGrant: (grant) => sql.query("identity_grants.record", `INSERT INTO cmux_vm.identity_vm_grants (id, tenant_id, identity_cmux_id, vm_cmux_id, upstream_id, allowed_linux_users, granted_at, granted_by) VALUES ($1,$2,$3,$4,$5,$6,$7::timestamptz,$8) ON CONFLICT (tenant_id, identity_cmux_id, vm_cmux_id) DO UPDATE SET allowed_linux_users = EXCLUDED.allowed_linux_users, revoked_at = NULL`, [grant.id, grant.tenantId, grant.identityCmuxId, grant.vmCmuxId, grant.upstreamId, grant.allowedLinuxUsers === null ? null : `{${grant.allowedLinuxUsers.join(",")}}`, grant.grantedAt.toISOString(), grant.grantedBy]).pipe(Effect.asVoid),
      listGrants: (tenantId, identityId) => sql.query("identity_grants.list", `SELECT id, tenant_id, identity_cmux_id, vm_cmux_id, upstream_id, allowed_linux_users, granted_at, granted_by FROM cmux_vm.identity_vm_grants WHERE tenant_id = $1 AND identity_cmux_id = $2 AND revoked_at IS NULL ORDER BY granted_at`, [tenantId, identityId]).pipe(Effect.flatMap(decode(GrantRow, "identity_grants.list")), Effect.map((rows) => rows.map(grantOf))),
      findGrant: (tenantId, identityId, vmId) => sql.query("identity_grants.find", `SELECT id, tenant_id, identity_cmux_id, vm_cmux_id, upstream_id, allowed_linux_users, granted_at, granted_by FROM cmux_vm.identity_vm_grants WHERE tenant_id = $1 AND identity_cmux_id = $2 AND vm_cmux_id = $3 AND revoked_at IS NULL LIMIT 1`, [tenantId, identityId, vmId]).pipe(Effect.flatMap(decode(GrantRow, "identity_grants.find")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), grantOf))),
      revokeGrant: (tenantId, identityId, vmId, at) => sql.query("identity_grants.revoke", `UPDATE cmux_vm.identity_vm_grants SET revoked_at = $4::timestamptz WHERE tenant_id = $1 AND identity_cmux_id = $2 AND vm_cmux_id = $3 AND revoked_at IS NULL`, [tenantId, identityId, vmId, at.toISOString()]).pipe(Effect.asVoid),
      revokeGrantsForVm: (tenantId, vmId, at) => sql.query("identity_grants.revokeVm", `UPDATE cmux_vm.identity_vm_grants SET revoked_at = $3::timestamptz WHERE tenant_id = $1 AND vm_cmux_id = $2 AND revoked_at IS NULL`, [tenantId, vmId, at.toISOString()]).pipe(Effect.asVoid),
      recordToken: (token) => sql.query("identity_tokens.record", `INSERT INTO cmux_vm.identity_tokens (id, tenant_id, identity_cmux_id, token_hash, created_at) VALUES ($1,$2,$3,$4,$5::timestamptz)`, [token.id, token.tenantId, token.identityCmuxId, token.tokenHash, token.createdAt.toISOString()]).pipe(Effect.asVoid),
      listTokens: (tenantId, identityId) => sql.query("identity_tokens.list", `SELECT id, tenant_id, identity_cmux_id, token_hash, created_at FROM cmux_vm.identity_tokens WHERE tenant_id = $1 AND identity_cmux_id = $2 AND revoked_at IS NULL ORDER BY created_at`, [tenantId, identityId]).pipe(Effect.flatMap(decode(TokenRow, "identity_tokens.list")), Effect.map((rows) => rows.map(tokenOf))),
      revokeToken: (tenantId, identityId, tokenId, at) => sql.query("identity_tokens.revoke", `UPDATE cmux_vm.identity_tokens SET revoked_at = $4::timestamptz WHERE tenant_id = $1 AND identity_cmux_id = $2 AND id = $3 AND revoked_at IS NULL`, [tenantId, identityId, tokenId, at.toISOString()]).pipe(Effect.asVoid),
      findToken: (tokenHash) => sql.query("identity_tokens.find", `SELECT id, tenant_id, identity_cmux_id, token_hash, created_at FROM cmux_vm.identity_tokens WHERE token_hash = $1 AND revoked_at IS NULL LIMIT 1`, [tokenHash]).pipe(Effect.flatMap(decode(TokenRow, "identity_tokens.find")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), tokenOf))),
    } satisfies IdentityStoreService;
  }),
);
