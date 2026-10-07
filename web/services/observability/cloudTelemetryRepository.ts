import { createHash, randomUUID } from "node:crypto";
import { type SQL, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { CLOUD_TELEMETRY_MAX_AGE_MS, type CloudTelemetryBatch, type CloudTelemetryClient, type CloudTelemetrySpan } from "./cloudTelemetryContract";
import { CloudTelemetryConflictError, CloudTelemetryLimitError } from "./cloudTelemetryIngest";

export type StoredCloudDiagnostic = {
  readonly userId: string;
  readonly eventId: string;
  readonly payload: {
    readonly client: CloudTelemetryClient; readonly span: CloudTelemetrySpan; readonly source?: "client" | "server"; readonly serverErrorCode?: string;
    readonly backend?: { tag?: string; revision?: string; sourceSha256?: string };
    /** Submitted spans this stored span represents after ingest sampling. Absent means 1. */
    readonly sampleWeight?: number;
  };
  readonly attempts: number;
};

/** Account quota and deduplication are transactional across all server instances. */
export async function acceptCloudTelemetry(
  userId: string, batch: CloudTelemetryBatch,
  options: { readonly serverErrorCode?: string; readonly sampleWeights?: ReadonlyMap<string, number> } = {},
): Promise<number> {
  const { serverErrorCode, sampleWeights } = options;
  const rows = batch.spans.map((span) => {
    const payload = { client: batch.client, span, source: serverErrorCode ? "server" : "client", ...(serverErrorCode ? { serverErrorCode } : {}) };
    const encoded = canonicalJSON(payload);
    // Hash only the submitted event: retries across deployments remain idempotent.
    // Store origin metadata separately so a later drain cannot relabel old errors.
    const backend = {
      tag: process.env.CMUX_DEV_BUILD_TAG ?? "unknown",
      revision: process.env.CMUX_DEV_BUILD_COMMIT ?? process.env.VERCEL_GIT_COMMIT_SHA ?? "unknown",
      sourceSha256: process.env.CMUX_DEV_BUILD_SOURCE_SHA256 ?? "unknown",
    };
    // The sample weight is ingest policy, not submitted evidence, so it stays outside the hash.
    const sampleWeight = sampleWeights?.get(span.eventId);
    const stored = { ...payload, backend, ...(sampleWeight && sampleWeight !== 1 ? { sampleWeight } : {}) };
    return { id: span.eventId, payload: canonicalJSON(stored), hash: createHash("sha256").update(encoded).digest("hex") };
  });
  return cloudDb().transaction(async (tx) => {
    await tx.execute(sql`set local statement_timeout = '3000ms'`);
    // One account lock also makes duplicate-content checks race-free.
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`cloud-diagnostics:${userId}`}, 0))`);
    const prior = await tx.execute(sql`
      select event_id::text, payload_hash from cloud_diagnostic_events
      where user_id = ${userId} and event_id in (${sql.join(rows.map((row) => sql`${row.id}::uuid`), sql`, `)})
    `);
    const existing = new Map(prior.map((row) => [String(row.event_id), String(row.payload_hash)]));
    for (const row of rows) {
      const previous = existing.get(row.id);
      if (previous && previous !== row.hash) throw new CloudTelemetryConflictError();
    }
    const pending = rows.filter((row) => !existing.has(row.id));
    if (pending.length === 0) return rows.length;
    const bytes = pending.reduce((sum, row) => sum + Buffer.byteLength(row.payload), 0);
    const minute = Math.floor(Date.now() / 60_000);
    const quota = await tx.execute(sql`
      insert into cloud_diagnostic_budgets (user_id, minute, bytes) values (${userId}, ${minute}, ${bytes})
      on conflict (user_id, minute) do update set bytes = cloud_diagnostic_budgets.bytes + excluded.bytes
      where cloud_diagnostic_budgets.bytes + excluded.bytes <= 262144 returning bytes
    `);
    if (!quota[0]) throw new CloudTelemetryLimitError();
    await tx.execute(sql`
      insert into cloud_diagnostic_events (user_id, event_id, payload, payload_hash)
      values ${sql.join(pending.map((row) => sql`(${userId}, ${row.id}::uuid, ${row.payload}::jsonb, ${row.hash})`), sql`, `)}
    `);
    return rows.length;
  });
}

export async function claimCloudDiagnostics(limit = 100, onlyOwner?: string): Promise<{ leaseId: string; rows: StoredCloudDiagnostic[] }> {
  const leaseId = randomUUID();
  const rows = await cloudDb().execute(sql`
    with pending as (
      select user_id, event_id from cloud_diagnostic_events
      where delivered_at is null and next_attempt_at <= now()
        ${onlyOwner ? sql`and user_id = ${onlyOwner}` : sql``}
      order by next_attempt_at limit ${Math.min(Math.max(limit, 1), 100)} for update skip locked
    )
    update cloud_diagnostic_events e set lease_id = ${leaseId}::uuid,
      next_attempt_at = now() + interval '2 minutes', attempts = attempts + 1
    from pending p where e.user_id = p.user_id and e.event_id = p.event_id
    returning e.user_id, e.event_id::text, e.payload, e.attempts
  `);
  return {
    leaseId,
    rows: rows.map((row) => ({
      userId: String(row.user_id), eventId: String(row.event_id),
      payload: row.payload as StoredCloudDiagnostic["payload"], attempts: Number(row.attempts),
    })),
  };
}

export type CloudDiagnosticsLease = {
  readonly leaseId: string;
  readonly rows: readonly Pick<StoredCloudDiagnostic, "userId" | "eventId">[];
};

export async function finishCloudDiagnostics(lease: CloudDiagnosticsLease, delivered: boolean): Promise<void> {
  if (lease.rows.length === 0) return;
  await cloudDb().execute(cloudDiagnosticsFinishStatement(lease, delivered));
}

/**
 * The acknowledgement for one claimed lease; exported so tests can inspect its plan.
 * `lease_id` has no index, and the delivered history holds millions of rows, so
 * the claimed primary keys select the rows. The lease check still stops a stale
 * worker from acknowledging rows that another drain has reclaimed.
 */
export function cloudDiagnosticsFinishStatement(lease: CloudDiagnosticsLease, delivered: boolean): SQL {
  const assignment = delivered
    ? sql`delivered_at = now(), lease_id = null`
    : sql`lease_id = null,
      next_attempt_at = now() + least(3600, 30 * power(2, least(attempts, 7))) * interval '1 second'`;
  const keys = sql.join(lease.rows.map((row) => sql`(${row.userId}, ${row.eventId}::uuid)`), sql`, `);
  return sql`
    update cloud_diagnostic_events set ${assignment}
    where (user_id, event_id) in (${keys}) and lease_id = ${lease.leaseId}::uuid
  `;
}

/**
 * A delivered row only deduplicates client retries. Ingest rejects a span that started
 * more than `CLOUD_TELEMETRY_MAX_AGE_MS` ago, and a span can start at most 5 minutes
 * after its first receipt (clock skew), so one extra hour bounds every retry window.
 */
export const CLOUD_DIAGNOSTICS_DELIVERED_RETENTION_SECONDS = CLOUD_TELEMETRY_MAX_AGE_MS / 1000 + 3600;
/** Undelivered rows wait this long for the export destination before they are lost. */
export const CLOUD_DIAGNOSTICS_UNDELIVERED_RETENTION_SECONDS = 7 * 24 * 3600;
const CLOUD_DIAGNOSTICS_EXPIRY_BATCH = 1000;

/**
 * Bounded retention. Return lost records so a full queue cannot disappear silently.
 * `onlyOwner` scopes the event deletes for tests that share a database; production runs globally.
 */
export async function expireCloudDiagnostics(onlyOwner?: string): Promise<{ expiredDelivered: number; expiredUndelivered: number; pending: number }> {
  const owner = onlyOwner ? sql`and user_id = ${onlyOwner}` : sql``;
  // Two bounded deletes per run, each walking the received_at index from its oldest row.
  // Each serves only its own window, so a delivered backlog cannot starve undelivered expiry.
  const delivered = await cloudDb().execute(sql`
    delete from cloud_diagnostic_events where (user_id, event_id) in (
      select user_id, event_id from cloud_diagnostic_events
      where received_at < now() - ${CLOUD_DIAGNOSTICS_DELIVERED_RETENTION_SECONDS} * interval '1 second'
        and delivered_at is not null ${owner}
      order by received_at limit ${CLOUD_DIAGNOSTICS_EXPIRY_BATCH}
    ) returning event_id
  `);
  const undelivered = await cloudDb().execute(sql`
    delete from cloud_diagnostic_events where (user_id, event_id) in (
      select user_id, event_id from cloud_diagnostic_events
      where received_at < now() - ${CLOUD_DIAGNOSTICS_UNDELIVERED_RETENTION_SECONDS} * interval '1 second'
        and delivered_at is null ${owner}
      order by received_at limit ${CLOUD_DIAGNOSTICS_EXPIRY_BATCH}
    ) returning event_id
  `);
  await cloudDb().execute(sql`delete from cloud_diagnostic_budgets where minute < ${Math.floor(Date.now() / 60_000) - 60}`);
  await cloudDb().execute(sql`delete from cloud_operation_steps where expires_at < now()`);
  const pending = await cloudDb().execute(sql`select count(*)::int as count from cloud_diagnostic_events where delivered_at is null`);
  return { expiredDelivered: delivered.length, expiredUndelivered: undelivered.length, pending: Number(pending[0]?.count ?? 0) };
}

function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => `${JSON.stringify(key)}:${canonicalJSON(child)}`).join(",")}}`;
  return JSON.stringify(value);
}
