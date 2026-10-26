/**
 * Agent keys and client sessions (migration 0016). Agent keys are rows of
 * cmux_vm.api_keys with agent_labels set; this store reads and revokes them by
 * id for their issuer, and lists the ones the reaper must clean up. Client
 * sessions record the provider identity behind each per-VM token so it can be
 * revoked; the token itself is never stored. Every statement is keyed by tenant
 * except the reaper's work lists, which return the tenant with each row.
 */
import { Context, Effect, Layer, Schema } from "effect";
import { ApiKeyId, ClientSessionId, TenantId, UpstreamId } from "../lib/ids.ts";
import { SqlClient, StoreError } from "./sql.ts";

export interface AgentKeyRow {
  readonly id: ApiKeyId;
  readonly tenantId: TenantId;
  /** `user:<id>`, `key:<id>` or `service:<id>` of the issuer. */
  readonly createdBy: string;
  readonly labels: Readonly<Record<string, string>>;
  readonly expiresAt: Date | null;
  readonly revokedAt: Date | null;
}

export interface ClientSessionRow {
  readonly id: ClientSessionId;
  readonly tenantId: TenantId;
  readonly vmId: string;
  /** The provider identity holding the grant and token. Internal only. */
  readonly upstreamIdentityId: UpstreamId;
  readonly linuxUser: string;
  readonly createdBy: string;
  readonly createdAt: Date;
  readonly revokedAt: Date | null;
}

/** A live client session with its live VM's labels, for the tenant-wide list (labels decide what a service key sees). */
export interface TenantClientSessionRow extends ClientSessionRow {
  readonly vmLabels: Readonly<Record<string, string>>;
}

export interface AgentStoreService {
  /** The tenant's agent key with this id (revoked or expired included), or null. */
  readonly findAgentKey: (tenantId: TenantId, id: ApiKeyId) => Effect.Effect<AgentKeyRow | null, StoreError>;
  /** Revokes the tenant's agent key; false when it has none. Revoking twice is not an error. */
  readonly revokeAgentKey: (tenantId: TenantId, id: ApiKeyId, at: Date) => Effect.Effect<boolean, StoreError>;
  /** Agent keys that expired or were revoked and still need their VMs cleaned up, oldest first. */
  readonly dueAgentKeys: (now: Date, limit: number) => Effect.Effect<ReadonlyArray<AgentKeyRow>, StoreError>;
  /** The reaper finished this key: no VM of it is left. */
  readonly markAgentCleaned: (tenantId: TenantId, id: ApiKeyId, at: Date) => Effect.Effect<void, StoreError>;
  readonly insertClientSession: (row: ClientSessionRow) => Effect.Effect<void, StoreError>;
  /** The VM's client sessions that are not revoked yet. */
  readonly liveClientSessions: (tenantId: TenantId, vmId: string) => Effect.Effect<ReadonlyArray<ClientSessionRow>, StoreError>;
  readonly findClientSession: (tenantId: TenantId, vmId: string, id: ClientSessionId) => Effect.Effect<ClientSessionRow | null, StoreError>;
  readonly markClientSessionRevoked: (tenantId: TenantId, id: ClientSessionId, at: Date) => Effect.Effect<void, StoreError>;
  /** Live client sessions whose VM is deleted: their revoke failed when the VM went. */
  readonly orphanClientSessions: (limit: number) => Effect.Effect<ReadonlyArray<ClientSessionRow>, StoreError>;
  /**
   * Records a live session's new Linux user (after the provider grant changed), only while its recorded user is
   * still `from`: a compare-and-set, false when another change got there first (or the session is gone).
   */
  readonly setClientSessionLinuxUser: (tenantId: TenantId, id: ClientSessionId, from: string, to: string) => Effect.Effect<boolean, StoreError>;
  /** The tenant's live client sessions on live VMs, by id after `after`, at most `limit`. */
  readonly liveTenantClientSessions: (
    tenantId: TenantId,
    after: ClientSessionId | null,
    limit: number,
  ) => Effect.Effect<ReadonlyArray<TenantClientSessionRow>, StoreError>;
}

export class AgentStore extends Context.Tag("cmux-vm/AgentStore")<AgentStore, AgentStoreService>() {}

const When = Schema.Union(Schema.DateFromSelf, Schema.Date);
const Labels = Schema.parseJson(Schema.Record({ key: Schema.String, value: Schema.String }));

const AgentRow = Schema.Struct({
  id: ApiKeyId,
  tenant_id: TenantId,
  created_by: Schema.String,
  agent_labels: Labels,
  expires_at: Schema.NullOr(When),
  revoked_at: Schema.NullOr(When),
});

const SessionRow = Schema.Struct({
  id: ClientSessionId,
  tenant_id: TenantId,
  vm_cmux_id: Schema.String,
  upstream_identity_id: UpstreamId,
  linux_user: Schema.String,
  created_by: Schema.String,
  created_at: When,
  revoked_at: Schema.NullOr(When),
});

const TenantSessionRow = Schema.Struct({ ...SessionRow.fields, vm_labels: Labels });

const AGENT_COLUMNS = "id, tenant_id, created_by, agent_labels::text AS agent_labels, expires_at, revoked_at";
const SESSION_COLUMNS = "s.id, s.tenant_id, s.vm_cmux_id, s.upstream_identity_id, s.linux_user, s.created_by, s.created_at, s.revoked_at";

const decode = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(schema))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));

const toAgent = (row: typeof AgentRow.Type): AgentKeyRow => ({
  id: row.id,
  tenantId: row.tenant_id,
  createdBy: row.created_by,
  labels: row.agent_labels,
  expiresAt: row.expires_at,
  revokedAt: row.revoked_at,
});

const toSession = (row: typeof SessionRow.Type): ClientSessionRow => ({
  id: row.id,
  tenantId: row.tenant_id,
  vmId: row.vm_cmux_id,
  upstreamIdentityId: row.upstream_identity_id,
  linuxUser: row.linux_user,
  createdBy: row.created_by,
  createdAt: row.created_at,
  revokedAt: row.revoked_at,
});

const toTenantSession = (row: typeof TenantSessionRow.Type): TenantClientSessionRow => ({ ...toSession(row), vmLabels: row.vm_labels });

export const sqlAgentStoreLayer: Layer.Layer<AgentStore, never, SqlClient> = Layer.effect(
  AgentStore,
  Effect.map(SqlClient, (sql): AgentStoreService => ({
    findAgentKey: (tenantId, id) =>
      sql
        .query("agents.find", `SELECT ${AGENT_COLUMNS} FROM cmux_vm.api_keys WHERE id = $1 AND tenant_id = $2 AND agent_labels IS NOT NULL LIMIT 1`, [id, tenantId])
        .pipe(Effect.flatMap(decode(AgentRow, "agents.find")), Effect.map((rows) => (rows[0] === undefined ? null : toAgent(rows[0])))),
    revokeAgentKey: (tenantId, id, at) =>
      sql
        .query(
          "agents.revoke",
          `UPDATE cmux_vm.api_keys SET revoked_at = COALESCE(revoked_at, $3::timestamptz)
            WHERE id = $1 AND tenant_id = $2 AND agent_labels IS NOT NULL
            RETURNING id`,
          [id, tenantId, at.toISOString()],
        )
        .pipe(Effect.map((rows) => rows.length > 0)),
    dueAgentKeys: (now, limit) =>
      sql
        .query(
          "agents.due",
          `SELECT ${AGENT_COLUMNS} FROM cmux_vm.api_keys
            WHERE agent_labels IS NOT NULL AND agent_cleaned_at IS NULL
              AND (revoked_at IS NOT NULL OR expires_at <= $1::timestamptz)
            ORDER BY COALESCE(revoked_at, expires_at), id
            LIMIT $2`,
          [now.toISOString(), limit],
        )
        .pipe(Effect.flatMap(decode(AgentRow, "agents.due")), Effect.map((rows) => rows.map(toAgent))),
    markAgentCleaned: (tenantId, id, at) =>
      sql
        .query(
          "agents.cleaned",
          `UPDATE cmux_vm.api_keys SET agent_cleaned_at = COALESCE(agent_cleaned_at, $3::timestamptz) WHERE id = $1 AND tenant_id = $2`,
          [id, tenantId, at.toISOString()],
        )
        .pipe(Effect.asVoid),
    insertClientSession: (row) =>
      sql
        .query(
          "clientSessions.insert",
          `INSERT INTO cmux_vm.vm_client_sessions (id, tenant_id, vm_cmux_id, upstream_identity_id, linux_user, created_by, created_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7::timestamptz)`,
          [row.id, row.tenantId, row.vmId, row.upstreamIdentityId, row.linuxUser, row.createdBy, row.createdAt.toISOString()],
        )
        .pipe(Effect.asVoid),
    liveClientSessions: (tenantId, vmId) =>
      sql
        .query(
          "clientSessions.live",
          `SELECT ${SESSION_COLUMNS} FROM cmux_vm.vm_client_sessions s
            WHERE s.tenant_id = $1 AND s.vm_cmux_id = $2 AND s.revoked_at IS NULL
            ORDER BY s.created_at, s.id`,
          [tenantId, vmId],
        )
        .pipe(Effect.flatMap(decode(SessionRow, "clientSessions.live")), Effect.map((rows) => rows.map(toSession))),
    findClientSession: (tenantId, vmId, id) =>
      sql
        .query(
          "clientSessions.find",
          `SELECT ${SESSION_COLUMNS} FROM cmux_vm.vm_client_sessions s WHERE s.id = $1 AND s.tenant_id = $2 AND s.vm_cmux_id = $3 LIMIT 1`,
          [id, tenantId, vmId],
        )
        .pipe(Effect.flatMap(decode(SessionRow, "clientSessions.find")), Effect.map((rows) => (rows[0] === undefined ? null : toSession(rows[0])))),
    markClientSessionRevoked: (tenantId, id, at) =>
      sql
        .query(
          "clientSessions.revoke",
          `UPDATE cmux_vm.vm_client_sessions SET revoked_at = COALESCE(revoked_at, $3::timestamptz) WHERE id = $1 AND tenant_id = $2`,
          [id, tenantId, at.toISOString()],
        )
        .pipe(Effect.asVoid),
    orphanClientSessions: (limit) =>
      sql
        .query(
          "clientSessions.orphans",
          `SELECT ${SESSION_COLUMNS} FROM cmux_vm.vm_client_sessions s
             JOIN cmux_vm.resources r ON r.tenant_id = s.tenant_id AND r.cmux_id = s.vm_cmux_id AND r.kind = 'vm'
            WHERE s.revoked_at IS NULL AND r.deleted_at IS NOT NULL
            ORDER BY s.created_at, s.id
            LIMIT $1`,
          [limit],
        )
        .pipe(Effect.flatMap(decode(SessionRow, "clientSessions.orphans")), Effect.map((rows) => rows.map(toSession))),
    setClientSessionLinuxUser: (tenantId, id, from, to) =>
      sql
        .query(
          "clientSessions.linuxUser",
          `UPDATE cmux_vm.vm_client_sessions SET linux_user = $4 WHERE id = $1 AND tenant_id = $2 AND revoked_at IS NULL AND linux_user = $3 RETURNING id`,
          [id, tenantId, from, to],
        )
        .pipe(Effect.map((rows) => rows.length === 1)),
    liveTenantClientSessions: (tenantId, after, limit) =>
      sql
        .query(
          "clientSessions.tenant",
          `SELECT ${SESSION_COLUMNS}, r.labels::text AS vm_labels FROM cmux_vm.vm_client_sessions s
             JOIN cmux_vm.resources r ON r.tenant_id = s.tenant_id AND r.cmux_id = s.vm_cmux_id AND r.kind = 'vm'
            WHERE s.tenant_id = $1 AND s.revoked_at IS NULL AND r.deleted_at IS NULL AND ($2::text IS NULL OR s.id COLLATE "C" > $2::text COLLATE "C")
            ORDER BY s.id COLLATE "C"
            LIMIT $3`,
          [tenantId, after, limit],
        )
        .pipe(Effect.flatMap(decode(TenantSessionRow, "clientSessions.tenant")), Effect.map((rows) => rows.map(toTenantSession))),
  })),
);
