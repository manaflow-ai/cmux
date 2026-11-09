/**
 * Enroll intents (migration 0018): a caller's own id for one device enroll, its revocation tombstone, and every create
 * attempt made under it.
 *
 * The row lock on (tenant, mesh, intent) orders an enroll's commit and a revoke without any time cutoff: the commit
 * inserts the device row in the same statement that marks the intent committed, and only while the intent is
 * unrevoked and still this attempt's; a revoke marks it revoked. Either the revoke sees the committed device (and
 * deletes it), or the commit inserts nothing (and the enroll deletes the tunnel it made).
 *
 * The revoke's authorization is part of that same write: it changes the row only when the caller is the claimant (or a
 * tenant admin), carries the row's labels, and, if confined to resources, has every attempt's device in its allowlist.
 *
 * Each attempt keeps its own row, so a later claim never hides an earlier attempt's tunnel. An attempt is resolved only
 * once nothing it made can be live; a claim's age never resolves it. The attempt's row lock orders its send with its
 * resolution: `markAttemptSent` sets sent_at only while the attempt is unresolved and still the intent's live claim,
 * and `resolveUnsentAttempt` sets resolved_at only while sent_at is unset, so an attempt resolved unsent never sends.
 */
import { Effect, Option, Schema } from "effect";
import type { TenantId } from "../lib/ids.ts";
import { StoreError, type SqlClientService } from "./sql.ts";
import type { MeshDeviceRow } from "./mesh.ts";

/** A revoked intent refuses enrolls this long. */
export const INTENT_TOMBSTONE_MS = 7 * 24 * 3_600_000;
/**
 * An enroll may reconcile (never resolve unseen) the live claim of a create this old that has not finished: it ends
 * that claim first, so the old create can no longer send or commit, then looks for its tunnel like a revoke does.
 */
export const INTENT_STALE_CLAIM_MS = 10 * 60_000;
/**
 * A provider create sent this long ago whose tunnel the provider does not have will never land (the Worker aborts the
 * request after 10 s; this is the bound the VM orphan sweep uses for a provider create to land). Before it, a lookup
 * that finds nothing proves nothing and the revoke answers 503.
 */
export const INTENT_SEND_GRACE_MS = 15 * 60_000;

type Labels = Readonly<Record<string, string>>;

export interface DeviceIntentRow {
  readonly meshId: string;
  readonly intentId: string;
  /** The live claim's attempt; null when no create holds the intent. */
  readonly deviceId: string | null;
  /** Every attempt's device, for the revoke's resource allowlist check. */
  readonly attemptDeviceIds: ReadonlyArray<string>;
  /** The claimant (or, for a tombstone written before any enroll, the revoker). */
  readonly createdBy: string;
  /** The claimant's required labels: what its device and tunnel rows carry, and what a revoker must carry. */
  readonly labels: Labels;
  readonly createdAt: Date;
  readonly committedAt: Date | null;
  readonly revokedAt: Date | null;
}

export interface IntentAttemptRow {
  readonly meshId: string;
  readonly intentId: string;
  readonly deviceId: string;
  readonly tunnelId: string;
  readonly createdAt: Date;
  /** Just before its provider create was sent; null if it never was. */
  readonly sentAt: Date | null;
  /** The provider's tunnel id, once its create answered. */
  readonly upstreamId: string | null;
  /** Its create returned: no commit can come from it any more. */
  readonly finishedAt: Date | null;
  /** Nothing it made can be live. */
  readonly resolvedAt: Date | null;
}

/** What an enroll with an intent finds: nothing holding it, its committed device, a live claim, or a tombstone. */
export type IntentState = "absent" | "committed" | "pending" | "revoked";

export const intentState = (row: Option.Option<DeviceIntentRow>, now: Date): IntentState => {
  if (Option.isNone(row)) return "absent";
  const intent = row.value;
  if (intent.revokedAt !== null) return now.getTime() - intent.revokedAt.getTime() < INTENT_TOMBSTONE_MS ? "revoked" : "absent";
  if (intent.committedAt !== null) return "committed";
  return intent.deviceId === null ? "absent" : "pending";
};

/** Whether an enroll may end this live claim and reconcile its attempt: its create finished, or is older than the stale window. */
export const claimIsReconcilable = (attempt: IntentAttemptRow, now: Date): boolean =>
  attempt.finishedAt !== null || now.getTime() - attempt.createdAt.getTime() >= INTENT_STALE_CLAIM_MS;

/** A sent attempt the provider has no tunnel for is resolved only if it answered, or once its send can no longer land. */
export const absenceIsFinal = (attempt: IntentAttemptRow, now: Date): boolean =>
  attempt.sentAt === null || attempt.upstreamId !== null || now.getTime() - attempt.sentAt.getTime() >= INTENT_SEND_GRACE_MS;

type AttemptKey = { readonly tenantId: TenantId; readonly meshId: string; readonly intentId: string; readonly deviceId: string };

export interface DeviceIntentStore {
  readonly findDeviceIntent: (tenantId: TenantId, meshId: string, intentId: string) => Effect.Effect<Option.Option<DeviceIntentRow>, StoreError>;
  /** The intent's attempts not yet resolved, oldest first. */
  readonly listOpenAttempts: (tenantId: TenantId, meshId: string, intentId: string) => Effect.Effect<ReadonlyArray<IntentAttemptRow>, StoreError>;
  readonly findAttempt: (key: AttemptKey) => Effect.Effect<Option.Option<IntentAttemptRow>, StoreError>;
  /**
   * In one statement: claims the intent for a new attempt and records the attempt. True when there was no row, or no
   * live claim on an unrevoked, uncommitted row, or an expired tombstone. False otherwise (nothing written).
   */
  readonly claimDeviceIntent: (
    tenantId: TenantId,
    meshId: string,
    intentId: string,
    claim: { readonly deviceId: string; readonly tunnelId: string; readonly createdBy: string; readonly labels: Labels },
    now: Date,
  ) => Effect.Effect<boolean, StoreError>;
  /** Sets sent_at just before the provider create, only while the attempt is unresolved and the intent's live, unrevoked claim. */
  readonly markAttemptSent: (key: AttemptKey, now: Date) => Effect.Effect<boolean, StoreError>;
  /** Records the provider's tunnel id once the create answered. */
  readonly recordAttemptTunnel: (key: AttemptKey, upstreamId: string) => Effect.Effect<void, StoreError>;
  /** The attempt's create returned. */
  readonly finishAttempt: (key: AttemptKey, now: Date) => Effect.Effect<void, StoreError>;
  /** Resolves an attempt that never sent; false (nothing written) once it has sent or is resolved already. */
  readonly resolveUnsentAttempt: (key: AttemptKey, now: Date) => Effect.Effect<boolean, StoreError>;
  /** Resolves an attempt whose tunnel is confirmed gone (or never made). */
  readonly resolveAttempt: (key: AttemptKey, now: Date) => Effect.Effect<void, StoreError>;
  /** In one statement: marks the claim committed and inserts the device row, only while the claim is still this device's and not revoked. */
  readonly commitDeviceIntent: (tenantId: TenantId, intentId: string, device: MeshDeviceRow, at: Date) => Effect.Effect<boolean, StoreError>;
  /**
   * Ends the live claim of `deviceId` (and its commit) so another enroll may claim the intent. Only for an attempt that is
   * resolved, or that a caller reconciles next. A revoked intent keeps its claim pointer.
   */
  readonly releaseDeviceIntent: (key: AttemptKey) => Effect.Effect<void, StoreError>;
  /** Undoes the commit of `deviceId` (its device was removed again) and keeps its claim: its attempt is not resolved. */
  readonly uncommitDeviceIntent: (key: AttemptKey) => Effect.Effect<void, StoreError>;
  /**
   * Writes (or refreshes an expired) tombstone, only for a caller who may: the row's claimant or a tenant admin, carrying
   * the row's labels, and (if confined to resources) holding every attempt's device in its allowlist. None when the row
   * exists and the caller may not (nothing written). A new row records the caller.
   */
  readonly revokeDeviceIntent: (
    tenantId: TenantId,
    meshId: string,
    intentId: string,
    caller: { readonly ref: string; readonly labels: Labels; readonly admin: boolean; readonly allowlist: ReadonlyArray<string> | null },
    now: Date,
  ) => Effect.Effect<Option.Option<DeviceIntentRow>, StoreError>;
  /** A deleted device's intent (if any) is revoked too, so a late repeat of its enroll refuses. */
  readonly revokeIntentOfDevice: (tenantId: TenantId, deviceId: string, at: Date) => Effect.Effect<void, StoreError>;
}

const When = Schema.Union(Schema.DateFromSelf, Schema.Date);
const Count = Schema.Union(Schema.Number, Schema.NumberFromString);
const Row = Schema.Struct({
  mesh_cmux_id: Schema.String,
  intent_id: Schema.String,
  device_cmux_id: Schema.NullOr(Schema.String),
  attempt_device_ids: Schema.parseJson(Schema.Array(Schema.String)),
  created_by: Schema.String,
  labels: Schema.parseJson(Schema.Record({ key: Schema.String, value: Schema.String })),
  created_at: When,
  committed_at: Schema.NullOr(When),
  revoked_at: Schema.NullOr(When),
});
const AttemptRow = Schema.Struct({
  mesh_cmux_id: Schema.String,
  intent_id: Schema.String,
  device_cmux_id: Schema.String,
  tunnel_cmux_id: Schema.String,
  created_at: When,
  sent_at: Schema.NullOr(When),
  upstream_id: Schema.NullOr(Schema.String),
  finished_at: Schema.NullOr(When),
  resolved_at: Schema.NullOr(When),
});
const Claimed = Schema.Struct({ claimed: Count });
const COLUMNS =
  "mesh_cmux_id, intent_id, device_cmux_id, array_to_json(attempt_device_ids)::text AS attempt_device_ids, created_by, labels::text AS labels, created_at, committed_at, revoked_at";
const ATTEMPT_COLUMNS = "mesh_cmux_id, intent_id, device_cmux_id, tunnel_cmux_id, created_at, sent_at, upstream_id, finished_at, resolved_at";
const ATTEMPT_KEY = "tenant_id = $1 AND mesh_cmux_id = $2 AND intent_id = $3 AND device_cmux_id = $4";

const decode = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(schema))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));
const toRow = (row: typeof Row.Type): DeviceIntentRow => ({
  meshId: row.mesh_cmux_id,
  intentId: row.intent_id,
  deviceId: row.device_cmux_id,
  attemptDeviceIds: row.attempt_device_ids,
  createdBy: row.created_by,
  labels: row.labels,
  createdAt: row.created_at,
  committedAt: row.committed_at,
  revokedAt: row.revoked_at,
});
const toAttempt = (row: typeof AttemptRow.Type): IntentAttemptRow => ({
  meshId: row.mesh_cmux_id,
  intentId: row.intent_id,
  deviceId: row.device_cmux_id,
  tunnelId: row.tunnel_cmux_id,
  createdAt: row.created_at,
  sentAt: row.sent_at,
  upstreamId: row.upstream_id,
  finishedAt: row.finished_at,
  resolvedAt: row.resolved_at,
});
const claimedOf = (operation: string) => (rows: ReadonlyArray<unknown>) =>
  decode(Claimed, operation)(rows).pipe(Effect.map((decoded) => (decoded[0]?.claimed ?? 0) > 0));
const ago = (now: Date, ms: number) => new Date(now.getTime() - ms).toISOString();
const carries = (rowLabels: Labels, required: Labels) => Object.entries(required).every(([key, value]) => rowLabels[key] === value);
const keyParams = (key: AttemptKey) => [key.tenantId, key.meshId, key.intentId, key.deviceId];

export const sqlDeviceIntents = (sql: SqlClientService): DeviceIntentStore => ({
  findDeviceIntent: (tenantId, meshId, intentId) =>
    sql
      .query(
        "intent.find",
        `SELECT ${COLUMNS} FROM cmux_vm.mesh_device_intents WHERE tenant_id = $1 AND mesh_cmux_id = $2 AND intent_id = $3 LIMIT 1`,
        [tenantId, meshId, intentId],
      )
      .pipe(Effect.flatMap(decode(Row, "intent.find")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), toRow))),
  listOpenAttempts: (tenantId, meshId, intentId) =>
    sql
      .query(
        "intent.listOpenAttempts",
        `SELECT ${ATTEMPT_COLUMNS} FROM cmux_vm.mesh_device_intent_attempts
          WHERE tenant_id = $1 AND mesh_cmux_id = $2 AND intent_id = $3 AND resolved_at IS NULL
          ORDER BY created_at, device_cmux_id LIMIT 100`,
        [tenantId, meshId, intentId],
      )
      .pipe(Effect.flatMap(decode(AttemptRow, "intent.listOpenAttempts")), Effect.map((rows) => rows.map(toAttempt))),
  findAttempt: (key) =>
    sql
      .query("intent.findAttempt", `SELECT ${ATTEMPT_COLUMNS} FROM cmux_vm.mesh_device_intent_attempts WHERE ${ATTEMPT_KEY}`, keyParams(key))
      .pipe(Effect.flatMap(decode(AttemptRow, "intent.findAttempt")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), toAttempt))),
  claimDeviceIntent: (tenantId, meshId, intentId, claim, now) =>
    sql
      .query(
        "intent.claim",
        `WITH claimed AS (
           INSERT INTO cmux_vm.mesh_device_intents (tenant_id, mesh_cmux_id, intent_id, device_cmux_id, attempt_device_ids, created_by, labels, created_at)
           VALUES ($1, $2, $3, $4, ARRAY[$4]::text[], $5, $8::text::jsonb, $6::timestamptz)
           ON CONFLICT (tenant_id, mesh_cmux_id, intent_id) DO UPDATE
             SET device_cmux_id = EXCLUDED.device_cmux_id,
                 attempt_device_ids = array_append(mesh_device_intents.attempt_device_ids, EXCLUDED.device_cmux_id),
                 created_by = EXCLUDED.created_by, labels = EXCLUDED.labels,
                 created_at = EXCLUDED.created_at, committed_at = NULL, revoked_at = NULL
             WHERE cardinality(mesh_device_intents.attempt_device_ids) < 1000
               AND ((mesh_device_intents.revoked_at IS NULL AND mesh_device_intents.committed_at IS NULL AND mesh_device_intents.device_cmux_id IS NULL)
                 OR mesh_device_intents.revoked_at <= $7::timestamptz)
           RETURNING tenant_id),
         attempt AS (
           INSERT INTO cmux_vm.mesh_device_intent_attempts (tenant_id, mesh_cmux_id, intent_id, device_cmux_id, tunnel_cmux_id, created_at)
           SELECT $1, $2, $3, $4, $9, $6::timestamptz FROM claimed
           RETURNING 1)
         SELECT count(*)::int AS claimed FROM attempt`,
        [tenantId, meshId, intentId, claim.deviceId, claim.createdBy, now.toISOString(), ago(now, INTENT_TOMBSTONE_MS), JSON.stringify(claim.labels), claim.tunnelId],
      )
      .pipe(Effect.flatMap(claimedOf("intent.claim"))),
  markAttemptSent: (key, now) =>
    sql
      .query(
        "intent.markSent",
        `WITH sent AS (
           UPDATE cmux_vm.mesh_device_intent_attempts SET sent_at = $5::timestamptz
            WHERE ${ATTEMPT_KEY} AND sent_at IS NULL AND resolved_at IS NULL
              AND EXISTS (SELECT 1 FROM cmux_vm.mesh_device_intents i
                           WHERE i.tenant_id = $1 AND i.mesh_cmux_id = $2 AND i.intent_id = $3 AND i.device_cmux_id = $4
                             AND i.revoked_at IS NULL AND i.committed_at IS NULL)
           RETURNING 1)
         SELECT count(*)::int AS claimed FROM sent`,
        [...keyParams(key), now.toISOString()],
      )
      .pipe(Effect.flatMap(claimedOf("intent.markSent"))),
  recordAttemptTunnel: (key, upstreamId) =>
    sql
      .query("intent.recordTunnel", `UPDATE cmux_vm.mesh_device_intent_attempts SET upstream_id = $5 WHERE ${ATTEMPT_KEY}`, [...keyParams(key), upstreamId])
      .pipe(Effect.asVoid),
  finishAttempt: (key, now) =>
    sql
      .query(
        "intent.finishAttempt",
        `UPDATE cmux_vm.mesh_device_intent_attempts SET finished_at = $5::timestamptz WHERE ${ATTEMPT_KEY} AND finished_at IS NULL`,
        [...keyParams(key), now.toISOString()],
      )
      .pipe(Effect.asVoid),
  resolveUnsentAttempt: (key, now) =>
    sql
      .query(
        "intent.resolveUnsent",
        `WITH resolved AS (
           UPDATE cmux_vm.mesh_device_intent_attempts SET resolved_at = $5::timestamptz
            WHERE ${ATTEMPT_KEY} AND sent_at IS NULL AND resolved_at IS NULL
           RETURNING 1)
         SELECT count(*)::int AS claimed FROM resolved`,
        [...keyParams(key), now.toISOString()],
      )
      .pipe(Effect.flatMap(claimedOf("intent.resolveUnsent"))),
  resolveAttempt: (key, now) =>
    sql
      .query(
        "intent.resolve",
        `UPDATE cmux_vm.mesh_device_intent_attempts SET resolved_at = $5::timestamptz WHERE ${ATTEMPT_KEY} AND resolved_at IS NULL`,
        [...keyParams(key), now.toISOString()],
      )
      .pipe(Effect.asVoid),
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
  releaseDeviceIntent: (key) =>
    sql
      .query(
        "intent.release",
        `UPDATE cmux_vm.mesh_device_intents SET device_cmux_id = NULL, committed_at = NULL
          WHERE tenant_id = $1 AND mesh_cmux_id = $2 AND intent_id = $3 AND device_cmux_id = $4 AND revoked_at IS NULL`,
        keyParams(key),
      )
      .pipe(Effect.asVoid),
  uncommitDeviceIntent: (key) =>
    sql
      .query(
        "intent.uncommit",
        `UPDATE cmux_vm.mesh_device_intents SET committed_at = NULL
          WHERE tenant_id = $1 AND mesh_cmux_id = $2 AND intent_id = $3 AND device_cmux_id = $4 AND revoked_at IS NULL`,
        keyParams(key),
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
             AND ($9::text IS NULL OR to_jsonb(mesh_device_intents.attempt_device_ids) <@ $9::text::jsonb)
         RETURNING ${COLUMNS}`,
        [
          tenantId,
          meshId,
          intentId,
          caller.ref,
          now.toISOString(),
          ago(now, INTENT_TOMBSTONE_MS),
          JSON.stringify(caller.labels),
          caller.admin,
          caller.allowlist === null ? null : JSON.stringify(caller.allowlist),
        ],
      )
      .pipe(Effect.flatMap(decode(Row, "intent.revoke")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), toRow))),
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

type Mutable<T> = { -readonly [K in keyof T]: T[K] };
type MemoryIntent = Mutable<DeviceIntentRow> & { readonly tenantId: string };
type MemoryAttempt = Mutable<IntentAttemptRow> & { readonly tenantId: string };

/** The same rules over arrays, for the in-memory store the Worker tests use. */
export const memoryDeviceIntents = (
  recordDevice: (tenantId: TenantId, device: MeshDeviceRow) => void,
): DeviceIntentStore & { readonly intents: () => ReadonlyArray<MemoryIntent>; readonly attempts: () => ReadonlyArray<MemoryAttempt> } => {
  const rows: MemoryIntent[] = [];
  const attempts: MemoryAttempt[] = [];
  const find = (tenantId: string, meshId: string, intentId: string) =>
    rows.find((row) => row.tenantId === tenantId && row.meshId === meshId && row.intentId === intentId);
  const findAttempt = (key: AttemptKey) =>
    attempts.find((row) => row.tenantId === key.tenantId && row.meshId === key.meshId && row.intentId === key.intentId && row.deviceId === key.deviceId);
  const copy = (row: MemoryIntent): DeviceIntentRow => ({ ...row, attemptDeviceIds: [...row.attemptDeviceIds] });
  return {
    intents: () => rows,
    attempts: () => attempts,
    findDeviceIntent: (tenantId, meshId, intentId) => Effect.sync(() => Option.map(Option.fromNullable(find(tenantId, meshId, intentId)), copy)),
    listOpenAttempts: (tenantId, meshId, intentId) =>
      Effect.sync(() =>
        attempts
          .filter((row) => row.tenantId === tenantId && row.meshId === meshId && row.intentId === intentId && row.resolvedAt === null)
          .map((row) => ({ ...row })),
      ),
    findAttempt: (key) => Effect.sync(() => Option.map(Option.fromNullable(findAttempt(key)), (row) => ({ ...row }))),
    claimDeviceIntent: (tenantId, meshId, intentId, claim, now) =>
      Effect.sync(() => {
        const fresh = { deviceId: claim.deviceId, createdBy: claim.createdBy, labels: claim.labels, createdAt: now, committedAt: null, revokedAt: null };
        const row = find(tenantId, meshId, intentId);
        if (row === undefined) {
          rows.push({ tenantId, meshId, intentId, attemptDeviceIds: [claim.deviceId], ...fresh });
        } else {
          const free = row.revokedAt === null && row.committedAt === null && row.deviceId === null;
          const expired = row.revokedAt !== null && now.getTime() - row.revokedAt.getTime() >= INTENT_TOMBSTONE_MS;
          if (row.attemptDeviceIds.length >= 1000 || !(free || expired)) return false;
          Object.assign(row, fresh, { attemptDeviceIds: [...row.attemptDeviceIds, claim.deviceId] });
        }
        attempts.push({ tenantId, meshId, intentId, deviceId: claim.deviceId, tunnelId: claim.tunnelId, createdAt: now, sentAt: null, upstreamId: null, finishedAt: null, resolvedAt: null });
        return true;
      }),
    markAttemptSent: (key, now) =>
      Effect.sync(() => {
        const attempt = findAttempt(key);
        const intent = find(key.tenantId, key.meshId, key.intentId);
        if (attempt === undefined || attempt.sentAt !== null || attempt.resolvedAt !== null) return false;
        if (intent === undefined || intent.deviceId !== key.deviceId || intent.revokedAt !== null || intent.committedAt !== null) return false;
        attempt.sentAt = now;
        return true;
      }),
    recordAttemptTunnel: (key, upstreamId) =>
      Effect.sync(() => {
        const attempt = findAttempt(key);
        if (attempt !== undefined) attempt.upstreamId = upstreamId;
      }),
    finishAttempt: (key, now) =>
      Effect.sync(() => {
        const attempt = findAttempt(key);
        if (attempt !== undefined && attempt.finishedAt === null) attempt.finishedAt = now;
      }),
    resolveUnsentAttempt: (key, now) =>
      Effect.sync(() => {
        const attempt = findAttempt(key);
        if (attempt === undefined || attempt.sentAt !== null || attempt.resolvedAt !== null) return false;
        attempt.resolvedAt = now;
        return true;
      }),
    resolveAttempt: (key, now) =>
      Effect.sync(() => {
        const attempt = findAttempt(key);
        if (attempt !== undefined && attempt.resolvedAt === null) attempt.resolvedAt = now;
      }),
    commitDeviceIntent: (tenantId, intentId, device, at) =>
      Effect.sync(() => {
        const row = find(tenantId, device.meshId, intentId);
        if (row === undefined || row.deviceId !== device.deviceId || row.committedAt !== null || row.revokedAt !== null) return false;
        row.committedAt = at;
        recordDevice(tenantId, device);
        return true;
      }),
    releaseDeviceIntent: (key) =>
      Effect.sync(() => {
        const row = find(key.tenantId, key.meshId, key.intentId);
        if (row !== undefined && row.deviceId === key.deviceId && row.revokedAt === null) Object.assign(row, { deviceId: null, committedAt: null });
      }),
    uncommitDeviceIntent: (key) =>
      Effect.sync(() => {
        const row = find(key.tenantId, key.meshId, key.intentId);
        if (row !== undefined && row.deviceId === key.deviceId && row.revokedAt === null) row.committedAt = null;
      }),
    revokeDeviceIntent: (tenantId, meshId, intentId, caller, now) =>
      Effect.sync(() => {
        const row = find(tenantId, meshId, intentId);
        if (row === undefined) {
          const created: MemoryIntent = { tenantId, meshId, intentId, deviceId: null, attemptDeviceIds: [], createdBy: caller.ref, labels: caller.labels, createdAt: now, committedAt: null, revokedAt: now };
          rows.push(created);
          return Option.some(copy(created));
        }
        const allowlist = caller.allowlist;
        const confined = allowlist !== null && row.attemptDeviceIds.some((device) => !allowlist.includes(device));
        if (!((row.createdBy === caller.ref || caller.admin) && carries(row.labels, caller.labels)) || confined) return Option.none();
        if (row.revokedAt === null || now.getTime() - row.revokedAt.getTime() >= INTENT_TOMBSTONE_MS) row.revokedAt = now;
        return Option.some(copy(row));
      }),
    revokeIntentOfDevice: (tenantId, deviceId, at) =>
      Effect.sync(() => {
        for (const row of rows) if (row.tenantId === tenantId && row.deviceId === deviceId && row.revokedAt === null) row.revokedAt = at;
      }),
  };
};
