/**
 * Enroll intents (migration 0018): a caller's own id for one device enroll, and its revocation tombstone.
 *
 * The row lock on (tenant, mesh, intent) orders an enroll's commit and a revoke without any time cutoff: the commit
 * inserts the device row in the same statement that marks the intent committed, and only while it is not revoked;
 * a revoke marks it revoked and reads whether a device was committed. Either the revoke sees the device (and deletes
 * it), or the commit inserts nothing (and the enroll deletes the tunnel it made).
 *
 * The revoke's authorization is part of that same write: it changes the row only when the caller is the row's
 * claimant (or a tenant admin) and carries the row's labels, so a claim made between a caller's read and its revoke
 * is never tombstoned by someone who may not.
 */
import { Effect, Option, Schema } from "effect";
import type { TenantId } from "../lib/ids.ts";
import { StoreError, type SqlClientService } from "./sql.ts";
import type { MeshDeviceRow } from "./mesh.ts";

/** A revoked intent refuses enrolls this long. */
export const INTENT_TOMBSTONE_MS = 7 * 24 * 3_600_000;
/** An uncommitted claim this old belongs to a create that died; another enroll may take it (the old commit then matches nothing). */
export const INTENT_STALE_CLAIM_MS = 10 * 60_000;

type Labels = Readonly<Record<string, string>>;

export interface DeviceIntentRow {
  readonly meshId: string;
  readonly intentId: string;
  /** The device the current claim creates; null once nothing of it can be live (released, cleaned up, or never enrolled). */
  readonly deviceId: string | null;
  /** The claimant (or, for a tombstone written before any enroll, the revoker). */
  readonly createdBy: string;
  /** The claimant's required labels: what its device and tunnel rows carry, and what a revoker must carry. */
  readonly labels: Labels;
  readonly createdAt: Date;
  readonly committedAt: Date | null;
  readonly revokedAt: Date | null;
  /** A refused create whose tunnel delete failed: this tunnel (its ownership rows still live) waits for a revoke to delete it. */
  readonly cleanupTunnelId: string | null;
}

/** What an enroll with an intent finds: nothing (claim it), its committed device, a live claim, or a tombstone. */
export type IntentState = "absent" | "committed" | "pending" | "revoked";

export const intentState = (row: Option.Option<DeviceIntentRow>, now: Date): IntentState => {
  if (Option.isNone(row)) return "absent";
  const intent = row.value;
  if (intent.revokedAt !== null) return now.getTime() - intent.revokedAt.getTime() < INTENT_TOMBSTONE_MS ? "revoked" : "absent";
  if (intent.committedAt !== null) return "committed";
  if (intent.deviceId === null || now.getTime() - intent.createdAt.getTime() >= INTENT_STALE_CLAIM_MS) return "absent";
  return "pending";
};

/** What a revoked intent still holds, for the revoke's answer. */
export type RevokedState =
  | { readonly _tag: "committed"; readonly deviceId: string }
  | { readonly _tag: "cleanup"; readonly deviceId: string; readonly tunnelId: string }
  | { readonly _tag: "in_flight" }
  | { readonly _tag: "settled" };

export const revokedState = (row: DeviceIntentRow, now: Date): RevokedState => {
  if (row.deviceId === null) return { _tag: "settled" };
  if (row.committedAt !== null) return { _tag: "committed", deviceId: row.deviceId };
  if (row.cleanupTunnelId !== null) return { _tag: "cleanup", deviceId: row.deviceId, tunnelId: row.cleanupTunnelId };
  // A create still between its claim and its commit; one older than the stale window died and left no known tunnel.
  return now.getTime() - row.createdAt.getTime() < INTENT_STALE_CLAIM_MS ? { _tag: "in_flight" } : { _tag: "settled" };
};

export interface DeviceIntentStore {
  readonly findDeviceIntent: (tenantId: TenantId, meshId: string, intentId: string) => Effect.Effect<Option.Option<DeviceIntentRow>, StoreError>;
  /**
   * Claims the intent for `deviceId`: true when there was no row, or its row was released, a stale claim or an
   * expired tombstone. False when it is committed, claimed by a live create or revoked.
   */
  readonly claimDeviceIntent: (
    tenantId: TenantId,
    meshId: string,
    intentId: string,
    claim: { readonly deviceId: string; readonly createdBy: string; readonly labels: Labels },
    now: Date,
  ) => Effect.Effect<boolean, StoreError>;
  /** In one statement: marks the claim committed and inserts the device row, only while the claim is still this device's and not revoked. */
  readonly commitDeviceIntent: (tenantId: TenantId, intentId: string, device: MeshDeviceRow, at: Date) => Effect.Effect<boolean, StoreError>;
  /**
   * Gives back the claim of `deviceId` after its create failed (before or after the commit: a failed ACL apply removes
   * the device again), so a retry with the intent may proceed. A revoked intent stays revoked.
   */
  readonly releaseDeviceIntent: (tenantId: TenantId, meshId: string, intentId: string, deviceId: string) => Effect.Effect<void, StoreError>;
  /**
   * Writes (or refreshes an expired) tombstone, only for a caller who may: the row's claimant or a tenant admin, carrying
   * the row's labels. None when the row exists and the caller may not (nothing written). A new row records the caller.
   */
  readonly revokeDeviceIntent: (
    tenantId: TenantId,
    meshId: string,
    intentId: string,
    caller: { readonly ref: string; readonly labels: Labels; readonly admin: boolean },
    now: Date,
  ) => Effect.Effect<Option.Option<DeviceIntentRow>, StoreError>;
  /** A refused create's tunnel is gone: nothing of `deviceId` can be live any more. */
  readonly settleDeviceIntent: (tenantId: TenantId, meshId: string, intentId: string, deviceId: string) => Effect.Effect<void, StoreError>;
  /** A refused create could not delete `tunnelId`: a revoke deletes it later. */
  readonly markDeviceIntentCleanup: (tenantId: TenantId, meshId: string, intentId: string, deviceId: string, tunnelId: string) => Effect.Effect<void, StoreError>;
  /** A deleted device's intent (if any) is revoked too, so a late repeat of its enroll refuses. */
  readonly revokeIntentOfDevice: (tenantId: TenantId, deviceId: string, at: Date) => Effect.Effect<void, StoreError>;
}

const When = Schema.Union(Schema.DateFromSelf, Schema.Date);
const Count = Schema.Union(Schema.Number, Schema.NumberFromString);
const Row = Schema.Struct({
  mesh_cmux_id: Schema.String,
  intent_id: Schema.String,
  device_cmux_id: Schema.NullOr(Schema.String),
  created_by: Schema.String,
  labels: Schema.parseJson(Schema.Record({ key: Schema.String, value: Schema.String })),
  created_at: When,
  committed_at: Schema.NullOr(When),
  revoked_at: Schema.NullOr(When),
  cleanup_tunnel_cmux_id: Schema.NullOr(Schema.String),
});
const Claimed = Schema.Struct({ claimed: Count });
const COLUMNS = "mesh_cmux_id, intent_id, device_cmux_id, created_by, labels::text AS labels, created_at, committed_at, revoked_at, cleanup_tunnel_cmux_id";
const RETURNING = "mesh_cmux_id, intent_id, device_cmux_id, created_by, labels::text AS labels, created_at, committed_at, revoked_at, cleanup_tunnel_cmux_id";

const decode = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(schema))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));
const toRow = (row: typeof Row.Type): DeviceIntentRow => ({
  meshId: row.mesh_cmux_id,
  intentId: row.intent_id,
  deviceId: row.device_cmux_id,
  createdBy: row.created_by,
  labels: row.labels,
  createdAt: row.created_at,
  committedAt: row.committed_at,
  revokedAt: row.revoked_at,
  cleanupTunnelId: row.cleanup_tunnel_cmux_id,
});
const claimedOf = (operation: string) => (rows: ReadonlyArray<unknown>) =>
  decode(Claimed, operation)(rows).pipe(Effect.map((decoded) => (decoded[0]?.claimed ?? 0) > 0));
const ago = (now: Date, ms: number) => new Date(now.getTime() - ms).toISOString();
const carries = (rowLabels: Labels, required: Labels) => Object.entries(required).every(([key, value]) => rowLabels[key] === value);

export const sqlDeviceIntents = (sql: SqlClientService): DeviceIntentStore => ({
  findDeviceIntent: (tenantId, meshId, intentId) =>
    sql
      .query(
        "intent.find",
        `SELECT ${COLUMNS} FROM cmux_vm.mesh_device_intents WHERE tenant_id = $1 AND mesh_cmux_id = $2 AND intent_id = $3 LIMIT 1`,
        [tenantId, meshId, intentId],
      )
      .pipe(Effect.flatMap(decode(Row, "intent.find")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), toRow))),
  claimDeviceIntent: (tenantId, meshId, intentId, claim, now) =>
    sql
      .query(
        "intent.claim",
        `WITH claimed AS (
           INSERT INTO cmux_vm.mesh_device_intents (tenant_id, mesh_cmux_id, intent_id, device_cmux_id, created_by, labels, created_at)
           VALUES ($1, $2, $3, $4, $5, $9::text::jsonb, $6::timestamptz)
           ON CONFLICT (tenant_id, mesh_cmux_id, intent_id) DO UPDATE
             SET device_cmux_id = EXCLUDED.device_cmux_id, created_by = EXCLUDED.created_by, labels = EXCLUDED.labels,
                 created_at = EXCLUDED.created_at, committed_at = NULL, revoked_at = NULL, cleanup_tunnel_cmux_id = NULL
             WHERE (mesh_device_intents.revoked_at IS NULL AND mesh_device_intents.committed_at IS NULL
                    AND (mesh_device_intents.device_cmux_id IS NULL OR mesh_device_intents.created_at <= $7::timestamptz))
                OR (mesh_device_intents.revoked_at <= $8::timestamptz AND mesh_device_intents.cleanup_tunnel_cmux_id IS NULL)
           RETURNING 1)
         SELECT count(*)::int AS claimed FROM claimed`,
        [
          tenantId,
          meshId,
          intentId,
          claim.deviceId,
          claim.createdBy,
          now.toISOString(),
          ago(now, INTENT_STALE_CLAIM_MS),
          ago(now, INTENT_TOMBSTONE_MS),
          JSON.stringify(claim.labels),
        ],
      )
      .pipe(Effect.flatMap(claimedOf("intent.claim"))),
  commitDeviceIntent: (tenantId, intentId, device, at) =>
    sql
      .query(
        "intent.commit",
        `WITH committed AS (
           UPDATE cmux_vm.mesh_device_intents SET committed_at = $10::timestamptz
            WHERE tenant_id = $2 AND mesh_cmux_id = $3 AND intent_id = $11 AND device_cmux_id = $1
              AND committed_at IS NULL AND revoked_at IS NULL
           RETURNING 1),
         inserted AS (
           INSERT INTO cmux_vm.mesh_devices (device_cmux_id, tenant_id, mesh_cmux_id, tunnel_cmux_id, name, wg_public_key, install_public_key, created_by, created_at)
           SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9::timestamptz FROM committed
           RETURNING 1)
         SELECT count(*)::int AS claimed FROM inserted`,
        [
          device.deviceId,
          tenantId,
          device.meshId,
          device.tunnelId,
          device.name,
          device.wgPublicKey,
          device.installPublicKey,
          device.createdBy,
          device.createdAt.toISOString(),
          at.toISOString(),
          intentId,
        ],
      )
      .pipe(Effect.flatMap(claimedOf("intent.commit"))),
  releaseDeviceIntent: (tenantId, meshId, intentId, deviceId) =>
    sql
      .query(
        "intent.release",
        `UPDATE cmux_vm.mesh_device_intents SET device_cmux_id = NULL, committed_at = NULL
          WHERE tenant_id = $1 AND mesh_cmux_id = $2 AND intent_id = $3 AND device_cmux_id = $4 AND revoked_at IS NULL`,
        [tenantId, meshId, intentId, deviceId],
      )
      .pipe(Effect.asVoid),
  revokeDeviceIntent: (tenantId, meshId, intentId, caller, now) =>
    sql
      .query(
        "intent.revoke",
        `INSERT INTO cmux_vm.mesh_device_intents (tenant_id, mesh_cmux_id, intent_id, device_cmux_id, created_by, labels, created_at, revoked_at)
         VALUES ($1, $2, $3, NULL, $4, $7::text::jsonb, $5::timestamptz, $5::timestamptz)
         ON CONFLICT (tenant_id, mesh_cmux_id, intent_id) DO UPDATE
           SET revoked_at = CASE WHEN mesh_device_intents.revoked_at IS NULL OR mesh_device_intents.revoked_at <= $6::timestamptz
                                 THEN EXCLUDED.revoked_at ELSE mesh_device_intents.revoked_at END
           WHERE (mesh_device_intents.created_by = $4 OR $8::boolean) AND mesh_device_intents.labels @> $7::text::jsonb
         RETURNING ${RETURNING}`,
        [tenantId, meshId, intentId, caller.ref, now.toISOString(), ago(now, INTENT_TOMBSTONE_MS), JSON.stringify(caller.labels), caller.admin],
      )
      .pipe(Effect.flatMap(decode(Row, "intent.revoke")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), toRow))),
  settleDeviceIntent: (tenantId, meshId, intentId, deviceId) =>
    sql
      .query(
        "intent.settle",
        `UPDATE cmux_vm.mesh_device_intents SET device_cmux_id = NULL, cleanup_tunnel_cmux_id = NULL
          WHERE tenant_id = $1 AND mesh_cmux_id = $2 AND intent_id = $3 AND device_cmux_id = $4 AND committed_at IS NULL`,
        [tenantId, meshId, intentId, deviceId],
      )
      .pipe(Effect.asVoid),
  markDeviceIntentCleanup: (tenantId, meshId, intentId, deviceId, tunnelId) =>
    sql
      .query(
        "intent.markCleanup",
        `UPDATE cmux_vm.mesh_device_intents SET cleanup_tunnel_cmux_id = $5
          WHERE tenant_id = $1 AND mesh_cmux_id = $2 AND intent_id = $3 AND device_cmux_id = $4 AND committed_at IS NULL`,
        [tenantId, meshId, intentId, deviceId, tunnelId],
      )
      .pipe(Effect.asVoid),
  revokeIntentOfDevice: (tenantId, deviceId, at) =>
    sql
      .query(
        "intent.revokeOfDevice",
        `UPDATE cmux_vm.mesh_device_intents SET revoked_at = $3::timestamptz
          WHERE tenant_id = $1 AND device_cmux_id = $2 AND revoked_at IS NULL`,
        [tenantId, deviceId, at.toISOString()],
      )
      .pipe(Effect.asVoid),
});

/** The same rules over an array, for the in-memory store the Worker tests use. */
export const memoryDeviceIntents = (recordDevice: (tenantId: TenantId, device: MeshDeviceRow) => void): DeviceIntentStore & { readonly intents: () => ReadonlyArray<DeviceIntentRow & { readonly tenantId: string }> } => {
  type Mutable = { -readonly [K in keyof DeviceIntentRow]: DeviceIntentRow[K] } & { readonly tenantId: string };
  const rows: Mutable[] = [];
  const find = (tenantId: string, meshId: string, intentId: string) =>
    rows.find((row) => row.tenantId === tenantId && row.meshId === meshId && row.intentId === intentId);
  const copy = (row: Mutable): DeviceIntentRow => ({ ...row });
  return {
    intents: () => rows,
    findDeviceIntent: (tenantId, meshId, intentId) => Effect.sync(() => Option.map(Option.fromNullable(find(tenantId, meshId, intentId)), copy)),
    claimDeviceIntent: (tenantId, meshId, intentId, claim, now) =>
      Effect.sync(() => {
        const fresh = { deviceId: claim.deviceId, createdBy: claim.createdBy, labels: claim.labels, createdAt: now, committedAt: null, revokedAt: null, cleanupTunnelId: null };
        const row = find(tenantId, meshId, intentId);
        if (row === undefined) {
          rows.push({ tenantId, meshId, intentId, ...fresh });
          return true;
        }
        if (intentState(Option.some(row), now) !== "absent" || row.cleanupTunnelId !== null) return false;
        Object.assign(row, fresh);
        return true;
      }),
    commitDeviceIntent: (tenantId, intentId, device, at) =>
      Effect.sync(() => {
        const row = find(tenantId, device.meshId, intentId);
        if (row === undefined || row.deviceId !== device.deviceId || row.committedAt !== null || row.revokedAt !== null) return false;
        row.committedAt = at;
        recordDevice(tenantId, device);
        return true;
      }),
    releaseDeviceIntent: (tenantId, meshId, intentId, deviceId) =>
      Effect.sync(() => {
        const row = find(tenantId, meshId, intentId);
        if (row !== undefined && row.deviceId === deviceId && row.revokedAt === null) Object.assign(row, { deviceId: null, committedAt: null });
      }),
    revokeDeviceIntent: (tenantId, meshId, intentId, caller, now) =>
      Effect.sync(() => {
        const row = find(tenantId, meshId, intentId);
        if (row === undefined) {
          const created: Mutable = { tenantId, meshId, intentId, deviceId: null, createdBy: caller.ref, labels: caller.labels, createdAt: now, committedAt: null, revokedAt: now, cleanupTunnelId: null };
          rows.push(created);
          return Option.some(copy(created));
        }
        if (!((row.createdBy === caller.ref || caller.admin) && carries(row.labels, caller.labels))) return Option.none();
        if (row.revokedAt === null || now.getTime() - row.revokedAt.getTime() >= INTENT_TOMBSTONE_MS) row.revokedAt = now;
        return Option.some(copy(row));
      }),
    settleDeviceIntent: (tenantId, meshId, intentId, deviceId) =>
      Effect.sync(() => {
        const row = find(tenantId, meshId, intentId);
        if (row !== undefined && row.deviceId === deviceId && row.committedAt === null) Object.assign(row, { deviceId: null, cleanupTunnelId: null });
      }),
    markDeviceIntentCleanup: (tenantId, meshId, intentId, deviceId, tunnelId) =>
      Effect.sync(() => {
        const row = find(tenantId, meshId, intentId);
        if (row !== undefined && row.deviceId === deviceId && row.committedAt === null) row.cleanupTunnelId = tunnelId;
      }),
    revokeIntentOfDevice: (tenantId, deviceId, at) =>
      Effect.sync(() => {
        for (const row of rows) if (row.tenantId === tenantId && row.deviceId === deviceId && row.revokedAt === null) row.revokedAt = at;
      }),
  };
};
