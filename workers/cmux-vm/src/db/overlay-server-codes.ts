import { Effect, Option, Schema } from "effect";
import { TenantId, type TenantId as Tenant } from "../lib/ids.ts";
import { StoreError, type SqlClientService } from "./sql.ts";
import type { OverlayServerRow } from "./overlay-servers.ts";

export interface OverlayServerCodeRow extends OverlayServerRow {
  readonly tenantId: Tenant;
  readonly codeSha256: string;
  readonly expiresAt: Date;
  readonly usedAt: Date | null;
  readonly burnedAt: Date | null;
}

export interface OverlayServerCodeStore {
  readonly insertOverlayServerCode: (row: OverlayServerCodeRow) => Effect.Effect<void, StoreError>;
  readonly findOverlayServerCode: (hash: string) => Effect.Effect<Option.Option<OverlayServerCodeRow>, StoreError>;
  readonly recentOverlayServerCodes: (tenant: Tenant, mesh: string, since: Date) => Effect.Effect<ReadonlyArray<OverlayServerCodeRow>, StoreError>;
  readonly burnOverlayServerCode: (hash: string, at: Date) => Effect.Effect<void, StoreError>;
  /** Registration and consumption commit together. Used codes can only acknowledge an exact live reservation. */
  readonly redeemOverlayServerCode: (tenant: Tenant, hash: string, mesh: string, at: Date) => Effect.Effect<boolean, StoreError>;
}

const Row = Schema.Struct({ code_sha256: Schema.String, tenant_id: TenantId, mesh_cmux_id: Schema.String, device_cmux_id: Schema.String, name: Schema.String, wg_public_key: Schema.String, install_public_key: Schema.String, created_by: Schema.String, created_at: Schema.DateFromSelf, expires_at: Schema.DateFromSelf, used_at: Schema.NullOr(Schema.DateFromSelf), burned_at: Schema.NullOr(Schema.DateFromSelf) });
const columns = "code_sha256, tenant_id, mesh_cmux_id, device_cmux_id, name, wg_public_key, install_public_key, created_by, created_at, expires_at, used_at, burned_at";
const decode = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: unknown) => Schema.decodeUnknown(schema)(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));
const toRow = (r: typeof Row.Type): OverlayServerCodeRow => ({ codeSha256: r.code_sha256, tenantId: r.tenant_id, meshId: r.mesh_cmux_id, deviceId: r.device_cmux_id, name: r.name, wgPublicKey: r.wg_public_key, installPublicKey: r.install_public_key, createdBy: r.created_by, createdAt: r.created_at, expiresAt: r.expires_at, usedAt: r.used_at, burnedAt: r.burned_at });

export const sqlOverlayServerCodes = (sql: SqlClientService): OverlayServerCodeStore => {
  const read = (op: string, where: string, params: ReadonlyArray<string>) => sql.query(op, `SELECT ${columns} FROM cmux_vm.mesh_overlay_server_codes WHERE ${where} ORDER BY created_at, code_sha256`, params).pipe(Effect.flatMap(decode(Schema.Array(Row), op)), Effect.map((rows) => rows.map(toRow)));
  return {
    insertOverlayServerCode: (r) => sql.query("serverCode.insert", `INSERT INTO cmux_vm.mesh_overlay_server_codes (${columns}) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,NULL,NULL)`, [r.codeSha256, r.tenantId, r.meshId, r.deviceId, r.name, r.wgPublicKey, r.installPublicKey, r.createdBy, r.createdAt.toISOString(), r.expiresAt.toISOString()]).pipe(Effect.asVoid),
    findOverlayServerCode: (hash) => read("serverCode.find", "code_sha256=$1", [hash]).pipe(Effect.map((rows) => Option.fromNullable(rows[0]))),
    recentOverlayServerCodes: (tenant, mesh, since) => read("serverCode.recent", "tenant_id=$1 AND mesh_cmux_id=$2 AND created_at>$3::timestamptz", [tenant, mesh, since.toISOString()]),
    burnOverlayServerCode: (hash, at) => sql.query("serverCode.burn", "UPDATE cmux_vm.mesh_overlay_server_codes SET burned_at=COALESCE(burned_at,$2::timestamptz) WHERE code_sha256=$1 AND used_at IS NULL", [hash, at.toISOString()]).pipe(Effect.asVoid),
    redeemOverlayServerCode: (tenant, hash, mesh, at) => sql.query("serverCode.redeem", `
      WITH valid AS MATERIALIZED (
        SELECT * FROM cmux_vm.mesh_overlay_server_codes
        WHERE tenant_id=$1 AND code_sha256=$2 AND mesh_cmux_id=$3 AND burned_at IS NULL AND expires_at>$4::timestamptz FOR UPDATE
      ), existing AS MATERIALIZED (
        SELECT s.device_cmux_id FROM cmux_vm.mesh_overlay_servers s JOIN valid c
          ON s.device_cmux_id=c.device_cmux_id AND s.tenant_id=c.tenant_id AND s.mesh_cmux_id=c.mesh_cmux_id
         AND s.name=c.name AND s.wg_public_key=c.wg_public_key AND s.install_public_key=c.install_public_key AND s.created_by=c.created_by
        WHERE s.revoked_at IS NULL
      ), inserted AS (
        INSERT INTO cmux_vm.mesh_overlay_servers (tenant_id, device_cmux_id, mesh_cmux_id, name, wg_public_key, install_public_key, created_by, created_at)
        SELECT tenant_id, device_cmux_id, mesh_cmux_id, name, wg_public_key, install_public_key, created_by, $4::timestamptz
          FROM valid WHERE used_at IS NULL AND NOT EXISTS (SELECT 1 FROM existing)
        ON CONFLICT DO NOTHING RETURNING device_cmux_id
      ), consumed AS (
        UPDATE cmux_vm.mesh_overlay_server_codes c SET used_at=COALESCE(c.used_at,$4::timestamptz)
          FROM valid v WHERE c.code_sha256=v.code_sha256
          AND EXISTS (SELECT 1 FROM existing UNION ALL SELECT 1 FROM inserted)
        RETURNING 1
      ) SELECT count(*)::int AS count FROM consumed`, [tenant, hash, mesh, at.toISOString()]).pipe(Effect.flatMap(decode(Schema.Array(Schema.Struct({ count: Schema.Number })), "serverCode.redeem")), Effect.map((rows) => (rows[0]?.count ?? 0) === 1)),
  };
};
