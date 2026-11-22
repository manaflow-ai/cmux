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
  readonly displayName: string | null;
  readonly labels: Readonly<Record<string, string>>;
}

/** Keyset position for paging newest first: the last row of the previous page. */
export interface PagePosition {
  readonly createdAt: Date;
  readonly cmuxId: string;
}

export interface ListPageOptions {
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
}

export interface OwnershipStoreService {
  /** The caller's own resource of this kind, or none. */
  readonly find: (tenantId: TenantId, kind: ResourceKind, cmuxId: string) => Effect.Effect<Option.Option<OwnedResource>, StoreError>;
  readonly record: (resource: OwnedResource) => Effect.Effect<void, StoreError>;
  /** The tenant's live resources of this kind, newest first. */
  readonly listPage: (tenantId: TenantId, kind: ResourceKind, options: ListPageOptions) => Effect.Effect<ReadonlyArray<OwnedResource>, StoreError>;
  /** How many live resources of this kind the tenant has. */
  readonly countLive: (tenantId: TenantId, kind: ResourceKind) => Effect.Effect<number, StoreError>;
  /** Marks the tenant's resource deleted; later reads do not find it. */
  readonly markDeleted: (tenantId: TenantId, kind: ResourceKind, cmuxId: string, at: Date) => Effect.Effect<void, StoreError>;
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
});

const CountRow = Schema.Struct({ live: Schema.Union(Schema.Number, Schema.NumberFromString) });

const RESOURCE_COLUMNS = "tenant_id, kind, cmux_id, upstream_id, created_by, created_at, display_name, labels::text AS labels";

const toOwned = (row: typeof ResourceRow.Type): OwnedResource => ({
  tenantId: row.tenant_id,
  kind: row.kind,
  cmuxId: row.cmux_id,
  upstreamId: row.upstream_id,
  createdBy: row.created_by,
  createdAt: row.created_at,
  displayName: row.display_name,
  labels: row.labels,
});

const ApiKeyRow = Schema.Struct({
  id: ApiKeyId,
  tenant_id: TenantId,
  scopes: words,
  resource_allowlist: words,
  expires_at: Schema.NullOr(Schema.Union(Schema.DateFromSelf, Schema.Date)),
});

const decodeRows = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(schema))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));

export const sqlStoresLayer: Layer.Layer<OwnershipStore | ApiKeyStore | AuditStore, never, SqlClient> = Layer.effectContext(
  Effect.gen(function* () {
    const sql = yield* SqlClient;

    const ownership: OwnershipStoreService = {
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
        ];
        return sql
          .query(
            "ownership.record",
            `INSERT INTO cmux_vm.resources (cmux_id, tenant_id, kind, upstream_id, created_by, created_at, display_name, labels)
             VALUES ($1, $2, $3, $4, $5, $6::timestamptz, $7, $8::text::jsonb)`,
            params,
          )
          .pipe(Effect.asVoid);
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
            `SELECT count(*)::int AS live FROM cmux_vm.resources WHERE tenant_id = $1 AND kind = $2 AND deleted_at IS NULL`,
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
                    expires_at`;
    const toKeyRecord = (operation: string) => (rows: ReadonlyArray<unknown>) =>
      decodeRows(ApiKeyRow, operation)(rows).pipe(
        Effect.map((decoded) =>
          Option.map(Option.fromNullable(decoded[0]), (row) => ({
            id: row.id,
            tenantId: row.tenant_id,
            scopes: row.scopes ?? [],
            resourceAllowlist: row.resource_allowlist,
            expiresAt: row.expires_at,
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
