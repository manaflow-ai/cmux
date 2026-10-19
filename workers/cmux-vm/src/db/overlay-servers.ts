import { Effect, Option, Schema } from "effect";
import { TenantId, type TenantId as Tenant } from "../lib/ids.ts";
import { StoreError, type SqlClientService } from "./sql.ts";

/** A destination in a mesh. It owns no provider resource and has no tunnel id. */
export interface OverlayServerRow {
  readonly deviceId: string;
  readonly meshId: string;
  readonly name: string;
  readonly wgPublicKey: string;
  readonly installPublicKey: string;
  readonly createdBy: string;
  readonly createdAt: Date;
}

export interface OverlayServerStore {
  readonly recordOverlayServer: (tenant: Tenant, row: OverlayServerRow) => Effect.Effect<boolean, StoreError>;
  readonly getOverlayServer: (tenant: Tenant, id: string) => Effect.Effect<Option.Option<OverlayServerRow>, StoreError>;
  readonly findOverlayServerForSignature: (id: string) => Effect.Effect<Option.Option<OverlayServerRow & { readonly tenantId: Tenant }>, StoreError>;
  readonly listOverlayServers: (tenant: Tenant, mesh: string) => Effect.Effect<ReadonlyArray<OverlayServerRow>, StoreError>;
  readonly revokeOverlayServer: (tenant: Tenant, id: string, at: Date) => Effect.Effect<void, StoreError>;
}

const Row = Schema.Struct({ device_cmux_id: Schema.String, mesh_cmux_id: Schema.String, name: Schema.String, wg_public_key: Schema.String, install_public_key: Schema.String, created_by: Schema.String, created_at: Schema.DateFromSelf });
const columns = "device_cmux_id, mesh_cmux_id, name, wg_public_key, install_public_key, created_by, created_at";
const toRow = (row: typeof Row.Type): OverlayServerRow => ({ deviceId: row.device_cmux_id, meshId: row.mesh_cmux_id, name: row.name, wgPublicKey: row.wg_public_key, installPublicKey: row.install_public_key, createdBy: row.created_by, createdAt: row.created_at });
const decode = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: unknown) => Schema.decodeUnknown(schema)(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));

export const sqlOverlayServers = (sql: SqlClientService): OverlayServerStore => {
  const get = (operation: string, where: string, params: ReadonlyArray<string>) => sql.query(operation, `SELECT ${columns} FROM cmux_vm.mesh_overlay_servers WHERE ${where} AND revoked_at IS NULL ORDER BY device_cmux_id`, params).pipe(Effect.flatMap(decode(Schema.Array(Row), operation)), Effect.map((rows) => rows.map(toRow)));
  return {
    recordOverlayServer: (tenant, row) => sql.query("overlay.record", `WITH inserted AS (INSERT INTO cmux_vm.mesh_overlay_servers (tenant_id, ${columns}) VALUES ($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT DO NOTHING RETURNING 1) SELECT count(*)::int AS count FROM inserted`, [tenant, row.deviceId, row.meshId, row.name, row.wgPublicKey, row.installPublicKey, row.createdBy, row.createdAt.toISOString()]).pipe(Effect.flatMap(decode(Schema.Array(Schema.Struct({ count: Schema.Number })), "overlay.record")), Effect.map((rows) => (rows[0]?.count ?? 0) === 1)),
    getOverlayServer: (tenant, id) => get("overlay.get", "tenant_id=$1 AND device_cmux_id=$2", [tenant, id]).pipe(Effect.map((rows) => Option.fromNullable(rows[0]))),
    findOverlayServerForSignature: (id) => sql.query("overlay.findForSignature", `SELECT tenant_id, ${columns} FROM cmux_vm.mesh_overlay_servers WHERE device_cmux_id=$1 AND revoked_at IS NULL`, [id]).pipe(Effect.flatMap(decode(Schema.Array(Schema.Struct({ ...Row.fields, tenant_id: TenantId })), "overlay.findForSignature")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), (row) => ({ ...toRow(row), tenantId: row.tenant_id })))),
    listOverlayServers: (tenant, mesh) => get("overlay.list", "tenant_id=$1 AND mesh_cmux_id=$2", [tenant, mesh]),
    revokeOverlayServer: (tenant, id, at) => sql.query("overlay.revoke", "UPDATE cmux_vm.mesh_overlay_servers SET revoked_at=$3 WHERE tenant_id=$1 AND device_cmux_id=$2 AND revoked_at IS NULL", [tenant, id, at.toISOString()]).pipe(Effect.asVoid),
  };
};
