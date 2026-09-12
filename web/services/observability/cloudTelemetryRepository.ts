import { createHash, randomUUID } from "node:crypto";
import { sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import type { CloudTelemetryBatch, CloudTelemetryClient, CloudTelemetrySpan } from "./cloudTelemetryContract";
import { CloudTelemetryConflictError, CloudTelemetryLimitError } from "./cloudTelemetryIngest";

export type StoredCloudDiagnostic = {
  readonly userId: string;
  readonly eventId: string;
  readonly payload: { readonly client: CloudTelemetryClient; readonly span: CloudTelemetrySpan; readonly source?: "client" | "server"; readonly serverErrorCode?: string };
  readonly attempts: number;
};

/** Account quota and deduplication are transactional across all server instances. */
export async function acceptCloudTelemetry(userId: string, batch: CloudTelemetryBatch, serverErrorCode?: string): Promise<number> {
  const rows = batch.spans.map((span) => {
    const payload = { client: batch.client, span, source: serverErrorCode ? "server" : "client", ...(serverErrorCode ? { serverErrorCode } : {}) };
    const encoded = canonicalJSON(payload);
    return { id: span.eventId, payload: encoded, hash: createHash("sha256").update(encoded).digest("hex") };
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

export async function finishCloudDiagnostics(leaseId: string, delivered: boolean): Promise<void> {
  if (delivered) {
    await cloudDb().execute(sql`update cloud_diagnostic_events set delivered_at = now(), lease_id = null where lease_id = ${leaseId}::uuid`);
  } else {
    await cloudDb().execute(sql`
      update cloud_diagnostic_events set lease_id = null,
      next_attempt_at = now() + least(3600, 30 * power(2, least(attempts, 7))) * interval '1 second'
      where lease_id = ${leaseId}::uuid
    `);
  }
}

/** Bounded retention. Return lost records so a full queue cannot disappear silently. */
export async function expireCloudDiagnostics(): Promise<{ expiredUndelivered: number; pending: number }> {
  const expired = await cloudDb().execute(sql`
    delete from cloud_diagnostic_events where (user_id, event_id) in (
      select user_id, event_id from cloud_diagnostic_events
      where received_at < now() - interval '7 days' order by received_at limit 1000
    ) returning delivered_at
  `);
  await cloudDb().execute(sql`delete from cloud_diagnostic_budgets where minute < ${Math.floor(Date.now() / 60_000) - 60}`);
  await cloudDb().execute(sql`delete from cloud_operation_steps where expires_at < now()`);
  const pending = await cloudDb().execute(sql`select count(*)::int as count from cloud_diagnostic_events where delivered_at is null`);
  return { expiredUndelivered: expired.filter((row) => row.delivered_at === null).length, pending: Number(pending[0]?.count ?? 0) };
}

function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => `${JSON.stringify(key)}:${canonicalJSON(child)}`).join(",")}}`;
  return JSON.stringify(value);
}
