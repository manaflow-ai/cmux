/**
 * Ownership and API key tables (migrations/). Every ownership read is keyed by
 * tenant: a row that belongs to another tenant is indistinguishable from a row
 * that does not exist.
 */
import { Context, Effect, Layer, Option, Schema } from "effect";
import { ApiKeyId, ResourceKind, TenantId, UpstreamId } from "../lib/ids.ts";
import { VmCreationReceipt } from "../api/creations.ts";
import { SqlClient, StoreError, type SqlParam } from "./sql.ts";

export interface OwnedResource {
  readonly creation?: { readonly key: string; readonly receipt: VmCreationReceipt };
  readonly tenantId: TenantId;
  readonly kind: ResourceKind;
  readonly cmuxId: string;
  readonly upstreamId: UpstreamId;
  readonly createdBy: string;
  readonly createdAt: Date;
  readonly displayName: string | null;
  readonly labels: Readonly<Record<string, string>>;
  /** False while the create that made this VM has not finished (its growth failed); absent means committed. */
  readonly committed?: boolean;
}

/** Keyset position for paging newest first: the last row of the previous page. */
export interface PagePosition {
  readonly createdAt: Date;
  readonly cmuxId: string;
}

export interface ListPageOptions {
  /** Exact persisted actor reference, derived from the authenticated principal. */
  readonly createdBy?: string;
  readonly limit: number;
  readonly after: PagePosition | null;
  /** When set, only these public ids (a key's resource allowlist). */
  readonly only: ReadonlySet<string> | null;
  /** When set, only resources carrying every one of these labels. */
  readonly labels: Readonly<Record<string, string>> | null;
}

/** One audit row: never command text, file contents or secrets. */
export interface AuditEntry {
  readonly tenantId: TenantId;
  /** `user:<id>`, `key:<id>`, `device:<id>` (a device-signed request) or `system:<name>`. */
  readonly actor: string;
  /** For a device or system actor: the principal it acted for or on (`user:<id>` or `key:<id>`); null otherwise. */
  readonly ownerActor: string | null;
  readonly action: string;
  readonly cmuxId: string | null;
  /** "ok" or the public error tag the caller received. */
  readonly outcome: string;
  readonly at: Date;
}

export interface ApiKeyRecord {
  readonly id: ApiKeyId;
  readonly tenantId: TenantId;
  readonly scopes: ReadonlyArray<string>;
  readonly resourceAllowlist: ReadonlyArray<string> | null;
  /** When the key stops working; null for no expiry. */
  readonly expiresAt: Date | null;
  /** Set for an agent key (migration 0016): the labels it is confined to and its budget. */
  readonly agent: AgentKeyRecord | null;
}

export interface AgentKeyRecord {
  readonly labels: Readonly<Record<string, string>>;
  readonly maxVms: number;
  readonly maxUsdPerHour: number;
}

export interface OwnershipStoreService {
  readonly findCreation: (tenantId: TenantId, key: string) => Effect.Effect<{ readonly receipt: VmCreationReceipt; readonly labels: Readonly<Record<string, string>>; readonly createdBy: string; readonly deleted: boolean; readonly committed: boolean } | null, StoreError>;
  /**
   * Recovery must distinguish a tombstone from an allocation never recorded, and a committed creation from a
   * recorded but unfinished one ("pending"). No private IDs leave this read.
   */
  readonly allocationStatus: (tenantId: TenantId, cmuxId: string) => Effect.Effect<"absent" | "pending" | "live" | "deleted", StoreError>;
  /** The creation key that made this VM, live or deleted, committed or not; null for a VM made without one. */
  readonly creationKey: (tenantId: TenantId, cmuxId: string) => Effect.Effect<string | null, StoreError>;
  /** The caller's own resource of this kind, or none. */
  readonly find: (tenantId: TenantId, kind: ResourceKind, cmuxId: string) => Effect.Effect<Option.Option<OwnedResource>, StoreError>;
  readonly record: (resource: OwnedResource) => Effect.Effect<void, StoreError>;
  /** The tenant's live resources of this kind, newest first. */
  readonly listPage: (tenantId: TenantId, kind: ResourceKind, options: ListPageOptions) => Effect.Effect<ReadonlyArray<OwnedResource>, StoreError>;
  /** How many live committed resources of this kind the tenant has; an uncommitted VM's slot is its creation's reservation. */
  readonly countLive: (tenantId: TenantId, kind: ResourceKind) => Effect.Effect<number, StoreError>;
  /** Marks the tenant's resource deleted; later reads do not find it. */
  readonly markDeleted: (tenantId: TenantId, kind: ResourceKind, cmuxId: string, at: Date) => Effect.Effect<void, StoreError>;
  /** The tenant's own resource of this kind that was marked deleted, or none (an idempotent delete's tombstone). */
  readonly findDeleted: (tenantId: TenantId, kind: ResourceKind, cmuxId: string) => Effect.Effect<Option.Option<OwnedResource>, StoreError>;
  /** Renames the tenant's live resource (null clears the name); false when there is none. Nothing but the display name changes. */
  readonly setDisplayName: (tenantId: TenantId, kind: ResourceKind, cmuxId: string, displayName: string | null) => Effect.Effect<boolean, StoreError>;
  /**
   * Compare-and-set of the display name and labels of the tenant's live committed resource (cx-b4h.2, cx-b4h.9):
   * applies only while the row still holds `expected`, so a decision taken on an older read (a label check) never
   * overwrites a newer change. False when the row is gone or changed.
   */
  readonly updateMetadata: (
    tenantId: TenantId,
    kind: ResourceKind,
    cmuxId: string,
    expected: { readonly displayName: string | null; readonly labels: Readonly<Record<string, string>> },
    metadata: { readonly displayName: string | null; readonly labels: Readonly<Record<string, string>> },
  ) => Effect.Effect<boolean, StoreError>;
}

export interface AuditStoreService {
  readonly append: (entry: AuditEntry) => Effect.Effect<void, StoreError>;
}

export interface ApiKeyStoreService {
  /** A live (not revoked, not expired at `now`) key with this SHA-256 hex hash, or none. */
  readonly findActiveByHash: (keyHash: string, now: Date) => Effect.Effect<Option.Option<ApiKeyRecord>, StoreError>;
  /**
   * The tenant's live key with this id, or none. Mesh M3 (cx-0op.5): a code or
   * a device-signed request that acts as an API key checks here that the key
   * was not revoked (or expired) since it made the code or enrolled the device.
   */
  readonly findActiveById: (tenantId: TenantId, id: ApiKeyId, now: Date) => Effect.Effect<Option.Option<ApiKeyRecord>, StoreError>;
}

export class OwnershipStore extends Context.Tag("cmux-vm/OwnershipStore")<OwnershipStore, OwnershipStoreService>() {}
export class ApiKeyStore extends Context.Tag("cmux-vm/ApiKeyStore")<ApiKeyStore, ApiKeyStoreService>() {}
export class AuditStore extends Context.Tag("cmux-vm/AuditStore")<AuditStore, AuditStoreService>() {}

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
  display_name: Schema.NullOr(Schema.String),
  labels: Schema.parseJson(Schema.Record({ key: Schema.String, value: Schema.String })),
  committed: Schema.Boolean,
});

const CountRow = Schema.Struct({ live: Schema.Union(Schema.Number, Schema.NumberFromString) });

const RESOURCE_COLUMNS = "tenant_id, kind, cmux_id, upstream_id, created_by, created_at, display_name, labels::text AS labels, committed";

const toOwned = (row: typeof ResourceRow.Type): OwnedResource => ({
  tenantId: row.tenant_id,
  kind: row.kind,
  cmuxId: row.cmux_id,
  upstreamId: row.upstream_id,
  createdBy: row.created_by,
  createdAt: row.created_at,
  displayName: row.display_name,
  labels: row.labels,
  ...(row.committed ? {} : { committed: false }),
});

const ApiKeyRow = Schema.Struct({
  id: ApiKeyId,
  tenant_id: TenantId,
  scopes: words,
  resource_allowlist: words,
  expires_at: Schema.NullOr(Schema.Union(Schema.DateFromSelf, Schema.Date)),
  agent_labels: Schema.NullOr(Schema.parseJson(Schema.Record({ key: Schema.String, value: Schema.String }))),
  agent_max_vms: Schema.NullOr(Schema.Union(Schema.Number, Schema.NumberFromString)),
  agent_max_usd_per_hour: Schema.NullOr(Schema.Union(Schema.Number, Schema.NumberFromString)),
});

const decodeRows = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(schema))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));

export const sqlStoresLayer: Layer.Layer<OwnershipStore | ApiKeyStore | AuditStore, never, SqlClient> = Layer.effectContext(
  Effect.gen(function* () {
    const sql = yield* SqlClient;

    const ownership: OwnershipStoreService = {
      findCreation: (tenantId, key) => sql.query("ownership.findCreation", `SELECT creation_receipt::text AS receipt, labels::text AS labels, created_by, deleted_at IS NOT NULL AS deleted, committed FROM cmux_vm.resources WHERE tenant_id = $1 AND creation_key = $2 AND kind = 'vm' ORDER BY created_at DESC, cmux_id DESC LIMIT 1`, [tenantId, key]).pipe(
        Effect.flatMap(decodeRows(Schema.Struct({ receipt: Schema.parseJson(VmCreationReceipt), labels: Schema.parseJson(Schema.Record({ key: Schema.String, value: Schema.String })), created_by: Schema.String, deleted: Schema.Boolean, committed: Schema.Boolean }), "ownership.findCreation")),
        Effect.map((rows) => rows[0] === undefined ? null : ({ receipt: rows[0].receipt, labels: rows[0].labels, createdBy: rows[0].created_by, deleted: rows[0].deleted, committed: rows[0].committed })),
      ),
      allocationStatus: (tenantId, cmuxId) => sql.query("ownership.allocationStatus", `SELECT deleted_at IS NOT NULL AS deleted, committed FROM cmux_vm.resources WHERE tenant_id = $1 AND cmux_id = $2 AND kind = 'vm' LIMIT 1`, [tenantId, cmuxId]).pipe(
        Effect.flatMap(decodeRows(Schema.Struct({ deleted: Schema.Boolean, committed: Schema.Boolean }), "ownership.allocationStatus")),
        Effect.map((rows) => rows[0] === undefined ? "absent" as const : rows[0].deleted ? "deleted" as const : rows[0].committed ? "live" as const : "pending" as const),
      ),
      creationKey: (tenantId, cmuxId) => sql.query("ownership.creationKey", `SELECT creation_key AS key FROM cmux_vm.resources WHERE tenant_id = $1 AND cmux_id = $2 AND kind = 'vm' AND creation_key IS NOT NULL LIMIT 1`, [tenantId, cmuxId]).pipe(
        Effect.flatMap(decodeRows(Schema.Struct({ key: Schema.String }), "ownership.creationKey")),
        Effect.map((rows) => rows[0]?.key ?? null),
      ),
      find: (tenantId, kind, cmuxId) =>
        sql
          .query(
            "ownership.find",
            `SELECT ${RESOURCE_COLUMNS}
               FROM cmux_vm.resources
              WHERE cmux_id = $1 AND tenant_id = $2 AND kind = $3 AND deleted_at IS NULL
              LIMIT 1`,
            [cmuxId, tenantId, kind],
          )
          .pipe(
            Effect.flatMap(decodeRows(ResourceRow, "ownership.find")),
            Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), toOwned)),
          ),
      record: (resource) => {
        const params: ReadonlyArray<SqlParam> = [
          resource.cmuxId,
          resource.tenantId,
          resource.kind,
          resource.upstreamId,
          resource.createdBy,
          resource.createdAt.toISOString(),
          resource.displayName,
          JSON.stringify(resource.labels),
          resource.creation?.key ?? null,
          resource.creation === undefined ? null : JSON.stringify(resource.creation.receipt),
          resource.committed ?? true,
        ];
        return sql
          .query(
            "ownership.record",
            // Recording the same allocation again may commit it, never uncommit it.
            `INSERT INTO cmux_vm.resources (cmux_id, tenant_id, kind, upstream_id, created_by, created_at, display_name, labels, creation_key, creation_receipt, committed)
             VALUES ($1, $2, $3, $4, $5, $6::timestamptz, $7, $8::text::jsonb, $9, $10::text::jsonb, $11)
             ON CONFLICT (cmux_id) DO UPDATE SET committed = resources.committed OR EXCLUDED.committed
             WHERE resources.tenant_id = EXCLUDED.tenant_id AND resources.kind = EXCLUDED.kind
               AND resources.upstream_id = EXCLUDED.upstream_id AND resources.created_by = EXCLUDED.created_by
               AND resources.display_name IS NOT DISTINCT FROM EXCLUDED.display_name AND resources.labels = EXCLUDED.labels
               AND resources.creation_key IS NOT DISTINCT FROM EXCLUDED.creation_key
               AND resources.creation_receipt IS NOT DISTINCT FROM EXCLUDED.creation_receipt
               AND resources.deleted_at IS NULL
             RETURNING cmux_id`,
            params,
          )
          .pipe(Effect.flatMap((rows) => rows.length === 1 ? Effect.void : Effect.fail(new StoreError({ operation: "ownership.record", cause: "allocation identity conflict" }))));
      },
      listPage: (tenantId, kind, options) => {
        const params: ReadonlyArray<SqlParam> = [
          tenantId,
          kind,
          options.after === null ? null : options.after.createdAt.toISOString(),
          options.after === null ? null : options.after.cmuxId,
          options.only === null ? null : [...options.only].join(" "),
          options.limit,
          options.labels === null ? null : JSON.stringify(options.labels),
          options.createdBy ?? null,
        ];
        return sql
          .query(
            "ownership.list",
            `SELECT ${RESOURCE_COLUMNS}
               FROM cmux_vm.resources
              WHERE tenant_id = $1 AND kind = $2 AND deleted_at IS NULL
                AND ($3::timestamptz IS NULL OR (created_at, cmux_id) < ($3::timestamptz, $4::text))
                AND ($5::text IS NULL OR cmux_id = ANY (string_to_array($5::text, ' ')))
                AND ($7::text::jsonb IS NULL OR labels @> $7::text::jsonb)
                AND ($8::text IS NULL OR created_by = $8::text)
              ORDER BY created_at DESC, cmux_id DESC
              LIMIT $6`,
            params,
          )
          .pipe(Effect.flatMap(decodeRows(ResourceRow, "ownership.list")), Effect.map((rows) => rows.map(toOwned)));
      },
      countLive: (tenantId, kind) =>
        sql
          .query(
            "ownership.count",
            `SELECT count(*)::int AS live FROM cmux_vm.resources WHERE tenant_id = $1 AND kind = $2 AND deleted_at IS NULL AND committed`,
            [tenantId, kind],
          )
          .pipe(
            Effect.flatMap(decodeRows(CountRow, "ownership.count")),
            Effect.map((rows) => rows[0]?.live ?? 0),
          ),
      markDeleted: (tenantId, kind, cmuxId, at) =>
        sql
          .query(
            "ownership.delete",
            `UPDATE cmux_vm.resources SET deleted_at = $4::timestamptz
              WHERE tenant_id = $1 AND kind = $2 AND cmux_id = $3 AND deleted_at IS NULL`,
            [tenantId, kind, cmuxId, at.toISOString()],
          )
          .pipe(Effect.asVoid),
      findDeleted: (tenantId, kind, cmuxId) =>
        sql
          .query(
            "ownership.findDeleted",
            `SELECT ${RESOURCE_COLUMNS}
               FROM cmux_vm.resources
              WHERE cmux_id = $1 AND tenant_id = $2 AND kind = $3 AND deleted_at IS NOT NULL
              LIMIT 1`,
            [cmuxId, tenantId, kind],
          )
          .pipe(
            Effect.flatMap(decodeRows(ResourceRow, "ownership.findDeleted")),
            Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), toOwned)),
          ),
      setDisplayName: (tenantId, kind, cmuxId, displayName) =>
        sql
          .query(
            "ownership.setDisplayName",
            `WITH updated AS (
               UPDATE cmux_vm.resources SET display_name = $4
                WHERE tenant_id = $1 AND kind = $2 AND cmux_id = $3 AND deleted_at IS NULL
               RETURNING 1)
             SELECT count(*)::int AS live FROM updated`,
            [tenantId, kind, cmuxId, displayName],
          )
          .pipe(
            Effect.flatMap(decodeRows(CountRow, "ownership.setDisplayName")),
            Effect.map((rows) => (rows[0]?.live ?? 0) > 0),
          ),
      updateMetadata: (tenantId, kind, cmuxId, expected, metadata) =>
        sql
          .query(
            "ownership.updateMetadata",
            `UPDATE cmux_vm.resources SET display_name = $4, labels = $5::text::jsonb
              WHERE tenant_id = $1 AND kind = $2 AND cmux_id = $3 AND deleted_at IS NULL AND committed
                AND display_name IS NOT DISTINCT FROM $6 AND labels = $7::text::jsonb
              RETURNING cmux_id`,
            [tenantId, kind, cmuxId, metadata.displayName, JSON.stringify(metadata.labels), expected.displayName, JSON.stringify(expected.labels)],
          )
          .pipe(Effect.map((rows) => rows.length === 1)),
    };

    const audit: AuditStoreService = {
      // Rows without an owner keep the pre-0007 statement, so they are written before 0007 is applied.
      append: (entry) =>
        (entry.ownerActor === null
          ? sql.query(
              "audit.append",
              `INSERT INTO cmux_vm.audit_log (tenant_id, actor, action, cmux_id, outcome, created_at)
               VALUES ($1, $2, $3, $4, $5, $6::timestamptz)`,
              [entry.tenantId, entry.actor, entry.action, entry.cmuxId, entry.outcome, entry.at.toISOString()],
            )
          : sql.query(
              "audit.appendOwned",
              `INSERT INTO cmux_vm.audit_log (tenant_id, actor, owner_actor, action, cmux_id, outcome, created_at)
               VALUES ($1, $2, $3, $4, $5, $6, $7::timestamptz)`,
              [entry.tenantId, entry.actor, entry.ownerActor, entry.action, entry.cmuxId, entry.outcome, entry.at.toISOString()],
            )
        ).pipe(Effect.asVoid),
    };

    const KEY_COLUMNS = `id, tenant_id,
                    array_to_string(scopes, ' ') AS scopes,
                    CASE WHEN resource_allowlist IS NULL THEN NULL
                         ELSE array_to_string(resource_allowlist, ' ') END AS resource_allowlist,
                    expires_at, agent_labels::text AS agent_labels, agent_max_vms, agent_max_usd_per_hour`;
    const toKeyRecord = (operation: string) => (rows: ReadonlyArray<unknown>) =>
      decodeRows(ApiKeyRow, operation)(rows).pipe(
        Effect.map((decoded) =>
          Option.map(Option.fromNullable(decoded[0]), (row) => ({
            id: row.id,
            tenantId: row.tenant_id,
            scopes: row.scopes ?? [],
            resourceAllowlist: row.resource_allowlist,
            expiresAt: row.expires_at,
            agent:
              row.agent_labels === null || row.agent_max_vms === null || row.agent_max_usd_per_hour === null
                ? null
                : { labels: row.agent_labels, maxVms: row.agent_max_vms, maxUsdPerHour: row.agent_max_usd_per_hour },
          })),
        ),
      );
    const apiKeys: ApiKeyStoreService = {
      findActiveByHash: (keyHash, now) =>
        sql
          .query(
            "api_keys.find",
            `SELECT ${KEY_COLUMNS}
               FROM cmux_vm.api_keys
              WHERE key_hash = $1
                AND revoked_at IS NULL
                AND (expires_at IS NULL OR expires_at > $2::timestamptz)
              LIMIT 1`,
            [keyHash, now.toISOString()],
          )
          .pipe(Effect.flatMap(toKeyRecord("api_keys.find"))),
      findActiveById: (tenantId, id, now) =>
        sql
          .query(
            "api_keys.findById",
            `SELECT ${KEY_COLUMNS}
               FROM cmux_vm.api_keys
              WHERE id = $1
                AND tenant_id = $2
                AND revoked_at IS NULL
                AND (expires_at IS NULL OR expires_at > $3::timestamptz)
              LIMIT 1`,
            [id, tenantId, now.toISOString()],
          )
          .pipe(Effect.flatMap(toKeyRecord("api_keys.findById"))),
    };

    return Context.make(OwnershipStore, ownership).pipe(Context.add(ApiKeyStore, apiKeys), Context.add(AuditStore, audit));
  }),
);
