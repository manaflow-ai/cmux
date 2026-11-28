/**
 * Snapshot rows of the ownership table (migrations 0001 and 0002). Every read
 * and write is keyed by tenant, so another tenant's snapshot is
 * indistinguishable from one that does not exist. Listing never asks the
 * provider: the table is the list.
 */
import { Context, Effect, Layer, Option, Schema } from "effect";
import { SnapshotId, TenantId, UpstreamId, VmId } from "../lib/ids.ts";
import { SqlClient, StoreError } from "./sql.ts";

export interface SnapshotRecord {
  readonly tenantId: TenantId;
  readonly id: SnapshotId;
  readonly upstreamId: UpstreamId;
  readonly sourceVmId: VmId | null;
  readonly displayName: string | null;
  readonly labels: Readonly<Record<string, string>>;
  readonly createdBy: string;
  readonly createdAt: Date;
}

/** What the table says about a snapshot, without its provider id. */
export interface SnapshotRow {
  readonly id: SnapshotId;
  readonly sourceVmId: VmId | null;
  readonly displayName: string | null;
  readonly labels: Readonly<Record<string, string>>;
  readonly createdAt: Date;
}

/** Keyset position: rows strictly older than (createdAt, id) in newest-first order. */
export interface SnapshotPage {
  readonly limit: number;
  readonly after: { readonly createdAt: Date; readonly id: string } | null;
  readonly sourceVmId: string | null;
  /** Only rows carrying every one of these labels. */
  readonly labels: Readonly<Record<string, string>> | null;
  /** When set, only these public ids (a key's resource allowlist). */
  readonly only: ReadonlyArray<string> | null;
}

export interface SnapshotStoreService {
  readonly record: (snapshot: SnapshotRecord) => Effect.Effect<void, StoreError>;
  /** The caller's own live snapshot, or none. */
  readonly describe: (tenantId: TenantId, id: SnapshotId) => Effect.Effect<Option.Option<SnapshotRow>, StoreError>;
  /** Up to `limit` of the tenant's live snapshots, newest first. */
  readonly list: (tenantId: TenantId, page: SnapshotPage) => Effect.Effect<ReadonlyArray<SnapshotRow>, StoreError>;
  /** Marks the tenant's snapshot deleted; a no-op for any other tenant's id. */
  readonly markDeleted: (tenantId: TenantId, id: SnapshotId, at: Date) => Effect.Effect<void, StoreError>;
}

export class SnapshotStore extends Context.Tag("cmux-vm/SnapshotStore")<SnapshotStore, SnapshotStoreService>() {}

const Row = Schema.Struct({
  cmux_id: SnapshotId,
  parent_cmux_id: Schema.NullOr(VmId),
  display_name: Schema.NullOr(Schema.String),
  labels: Schema.NullOr(Schema.Union(Schema.Record({ key: Schema.String, value: Schema.String }), Schema.parseJson(Schema.Record({ key: Schema.String, value: Schema.String })))),
  created_at: Schema.Union(Schema.DateFromSelf, Schema.Date),
});

const decodeRows = (operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(Row))(rows).pipe(
    Effect.map((decoded) =>
      decoded.map(
        (row): SnapshotRow => ({
          id: row.cmux_id,
          sourceVmId: row.parent_cmux_id,
          displayName: row.display_name,
          labels: row.labels ?? {},
          createdAt: row.created_at,
        }),
      ),
    ),
    Effect.mapError((cause) => new StoreError({ operation, cause })),
  );

const COLUMNS = "cmux_id, parent_cmux_id, display_name, labels, created_at";

export const sqlSnapshotStoreLayer: Layer.Layer<SnapshotStore, never, SqlClient> = Layer.effect(
  SnapshotStore,
  Effect.gen(function* () {
    const sql = yield* SqlClient;
    return {
      record: (snapshot) =>
        sql
          .query(
            "snapshots.record",
            `INSERT INTO cmux_vm.resources
               (cmux_id, tenant_id, kind, upstream_id, created_by, created_at, parent_cmux_id, display_name, labels)
             VALUES ($1, $2, 'snapshot', $3, $4, $5::timestamptz, $6, $7, $8::text::jsonb)`,
            [
              snapshot.id,
              snapshot.tenantId,
              snapshot.upstreamId,
              snapshot.createdBy,
              snapshot.createdAt.toISOString(),
              snapshot.sourceVmId,
              snapshot.displayName,
              JSON.stringify(snapshot.labels),
            ],
          )
          .pipe(Effect.asVoid),
      describe: (tenantId, id) =>
        sql
          .query(
            "snapshots.describe",
            `SELECT ${COLUMNS} FROM cmux_vm.resources
              WHERE cmux_id = $1 AND tenant_id = $2 AND kind = 'snapshot' AND deleted_at IS NULL
              LIMIT 1`,
            [id, tenantId],
          )
          .pipe(Effect.flatMap(decodeRows("snapshots.describe")), Effect.map((rows) => Option.fromNullable(rows[0]))),
      list: (tenantId, page) =>
        sql
          .query(
            "snapshots.list",
            `SELECT ${COLUMNS} FROM cmux_vm.resources
              WHERE tenant_id = $1 AND kind = 'snapshot' AND deleted_at IS NULL
                AND ($2::text IS NULL OR parent_cmux_id = $2::text)
                AND ($3::timestamptz IS NULL OR (created_at, cmux_id) < ($3::timestamptz, $4::text))
                AND ($6::text::jsonb IS NULL OR labels @> $6::text::jsonb)
                AND ($7::text::jsonb IS NULL OR $7::text::jsonb ? cmux_id)
              ORDER BY created_at DESC, cmux_id DESC
              LIMIT $5`,
            [
              tenantId,
              page.sourceVmId,
              page.after === null ? null : page.after.createdAt.toISOString(),
              page.after === null ? null : page.after.id,
              page.limit,
              page.labels === null ? null : JSON.stringify(page.labels),
              page.only === null ? null : JSON.stringify(page.only),
            ],
          )
          .pipe(Effect.flatMap(decodeRows("snapshots.list"))),
      markDeleted: (tenantId, id, at) =>
        sql
          .query(
            "snapshots.markDeleted",
            `UPDATE cmux_vm.resources SET deleted_at = $3::timestamptz
              WHERE cmux_id = $1 AND tenant_id = $2 AND kind = 'snapshot' AND deleted_at IS NULL`,
            [id, tenantId, at.toISOString()],
          )
          .pipe(Effect.asVoid),
    };
  }),
);
