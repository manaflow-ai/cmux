import { randomUUID } from "node:crypto";
import { sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { canApplyRunAttemptMutation, isRunAttemptLeaseActive, runAttemptTransitionDecision, type RunAttemptTerminalStatus } from "./worker-contract";

export { canApplyRunAttemptMutation, isRunAttemptLeaseActive, runAttemptTransitionDecision };

const DEFAULT_LEASE_MS = 60_000;
const MAX_LEASE_MS = 15 * 60_000;
type CloudTransaction = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

function boundedLeaseMs(value: number | undefined): number {
  if (!Number.isFinite(value)) return DEFAULT_LEASE_MS;
  return Math.max(1_000, Math.min(Math.trunc(value as number), MAX_LEASE_MS));
}

function rowString(row: Record<string, unknown>, key: string): string {
  const value = row[key];
  if (typeof value !== "string" || value.length === 0) throw new Error(`Run attempt query returned invalid ${key}`);
  return value;
}

function rowDate(row: Record<string, unknown>, key: string): Date {
  const value = row[key];
  const parsed = value instanceof Date ? value : new Date(String(value));
  if (Number.isNaN(parsed.getTime())) throw new Error(`Run attempt query returned invalid ${key}`);
  return parsed;
}

function rowRecord(row: Record<string, unknown>, key: string): Record<string, unknown> {
  const value = row[key];
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`Run attempt query returned invalid ${key}`);
  return value as Record<string, unknown>;
}

/**
 * Atomically claims one queued or expired attempt. The database is the queue:
 * FOR UPDATE SKIP LOCKED gives each worker a distinct item and the lease UUID
 * fences late provider responses after a worker stalls or is replaced.
 */
export async function claimNextRunAttempt(input: {
  readonly workerId: string;
  readonly leaseMs?: number;
  readonly now?: Date;
}): Promise<ClaimedRunAttempt | null> {
  const now = input.now ?? new Date();
  const leaseUntil = new Date(now.getTime() + boundedLeaseMs(input.leaseMs));
  const leaseId = randomUUID();
  return await cloudDb().transaction(async (tx) => {
    const rows = await tx.execute(sql`
      with candidate as (
        select a.id
        from run_attempts a
        join runs r on r.id = a.run_id
        where r.status in ('queued', 'running')
          and a.cancel_requested_at is null
          and (
            a.status = 'queued'
            or (a.status = 'running' and (a.lease_until is null or a.lease_until <= ${now}))
          )
        order by a.created_at asc, a.ordinal asc, a.id asc
        for update of a skip locked
        limit 1
      )
      update run_attempts a
      set status = 'running',
          lease_id = ${leaseId}::uuid,
          lease_until = ${leaseUntil},
          worker_id = ${input.workerId},
          started_at = coalesce(a.started_at, ${now}),
          updated_at = ${now}
      from candidate
      where a.id = candidate.id
      returning a.run_id::text, a.id::text, a.ordinal, a.variant,
        a.lease_id::text, a.lease_until, a.worker_id
    `) as readonly Record<string, unknown>[];
    const row = rows[0];
    if (!row) return null;
    const claimed = {
      runId: rowString(row, "run_id"),
      attemptId: rowString(row, "id"),
      ordinal: Number(row.ordinal),
      variant: rowRecord(row, "variant"),
      leaseId: rowString(row, "lease_id"),
      leaseUntil: rowDate(row, "lease_until"),
      workerId: rowString(row, "worker_id"),
    } satisfies ClaimedRunAttempt;
    await tx.execute(sql`update runs set status = 'running', updated_at = ${now} where id = ${claimed.runId}::uuid and status <> 'cancelled'`);
    await appendRunEvent(tx, claimed.runId, claimed.attemptId, "attempt.started", { workerId: claimed.workerId, leaseId: claimed.leaseId });
    return claimed;
  });
}

/** Extend only the current lease; an expired or superseded worker cannot renew. */
export async function renewRunAttemptLease(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseId: string;
  readonly leaseMs?: number;
  readonly now?: Date;
}): Promise<boolean> {
  const now = input.now ?? new Date();
  const leaseUntil = new Date(now.getTime() + boundedLeaseMs(input.leaseMs));
  const rows = await cloudDb().execute(sql`
    update run_attempts
    set lease_until = ${leaseUntil}, updated_at = ${now}
    where run_id = ${input.runId}::uuid and id = ${input.attemptId}::uuid
      and status = 'running' and lease_id = ${input.leaseId}::uuid
      and lease_until > ${now}
      and cancel_requested_at is null
    returning id
  `) as readonly Record<string, unknown>[];
  return rows.length > 0;
}

/**
 * Commits a terminal result exactly once. A replay with the same lease is a
 * no-op after the first transition; a stale lease is fenced and cannot append
 * a second terminal event or mutate the provider identity.
 */
export async function finishRunAttempt(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseId: string;
  readonly status: Exclude<RunAttemptTerminalStatus, "cancelled">;
  readonly providerVmId?: string | null;
  readonly result?: Record<string, unknown>;
  readonly error?: string | null;
  readonly now?: Date;
}): Promise<boolean> {
  return await transitionRunAttempt({ ...input, status: input.status, now: input.now });
}

export async function cancelClaimedRunAttempt(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseId: string;
  readonly now?: Date;
}): Promise<boolean> {
  return await transitionRunAttempt({ ...input, status: "cancelled", now: input.now });
}

async function transitionRunAttempt(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseId: string;
  readonly status: RunAttemptTerminalStatus;
  readonly providerVmId?: string | null;
  readonly result?: Record<string, unknown>;
  readonly error?: string | null;
  readonly now?: Date;
}): Promise<boolean> {
  const now = input.now ?? new Date();
  return await cloudDb().transaction(async (tx) => {
    const rows = await tx.execute(sql`
      update run_attempts
      set status = ${input.status}::run_attempt_status,
          provider_vm_id = coalesce(${input.providerVmId ?? null}, provider_vm_id),
          result = coalesce(${input.result ? JSON.stringify(input.result) : null}::jsonb, result),
          error = ${input.error?.slice(0, 1_000) ?? null},
          finished_at = ${now}, lease_until = null, updated_at = ${now}
      where run_id = ${input.runId}::uuid and id = ${input.attemptId}::uuid
        and status = 'running' and lease_id = ${input.leaseId}::uuid
        and lease_until > ${now}
      returning id
    `) as readonly Record<string, unknown>[];
    if (rows.length === 0) return false;
    await appendRunEvent(tx, input.runId, input.attemptId, input.status === "succeeded" ? "attempt.succeeded" : input.status === "failed" ? "attempt.failed" : "attempt.cancelled", {
      ...(input.status === "failed" && input.error ? { error: input.error.slice(0, 1_000) } : {}),
      ...(input.status === "cancelled" ? { reason: "run_cancelled" } : {}),
    });
    await tx.execute(sql`
      update runs
      set status = case
        when status = 'cancelled' then status
        when exists (select 1 from run_attempts where run_id = ${input.runId}::uuid and status in ('queued', 'running')) then 'running'::run_status
        when exists (select 1 from run_attempts where run_id = ${input.runId}::uuid and status = 'failed') then 'failed'::run_status
        when exists (select 1 from run_attempts where run_id = ${input.runId}::uuid and status = 'cancelled') then 'cancelled'::run_status
        else 'succeeded'::run_status
      end,
      completed_at = case when not exists (select 1 from run_attempts where run_id = ${input.runId}::uuid and status in ('queued', 'running')) then ${now} else completed_at end,
      updated_at = ${now}
      where id = ${input.runId}::uuid
    `);
    return true;
  });
}

/** Request cancellation without revoking a worker's lease mid-provider call. */
export async function cancelRun(input: { readonly runId: string; readonly now?: Date }): Promise<boolean> {
  const now = input.now ?? new Date();
  return await cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run:${input.runId}`}, 0))`);
    const runRows = await tx.execute(sql`select status from runs where id = ${input.runId}::uuid for update`) as readonly Record<string, unknown>[];
    if (runRows.length === 0 || runRows[0]?.status === "cancelled") return false;
    const queued = await tx.execute(sql`
      update run_attempts set status = 'cancelled', finished_at = ${now}, updated_at = ${now}
      where run_id = ${input.runId}::uuid and status = 'queued'
      returning id::text
    `) as readonly Record<string, unknown>[];
    await tx.execute(sql`
      update run_attempts set cancel_requested_at = ${now}, updated_at = ${now}
      where run_id = ${input.runId}::uuid and status = 'running'
    `);
    await tx.execute(sql`update runs set status = 'cancelled', completed_at = ${now}, updated_at = ${now} where id = ${input.runId}::uuid`);
    for (const row of queued) {
      await appendRunEvent(tx, input.runId, rowString(row, "id"), "attempt.cancelled", { reason: "run_cancelled" });
    }
    await appendRunEvent(tx, input.runId, null, "run.cancelled", { cancelledQueuedAttempts: queued.length });
    return true;
  });
}

/** One bounded worker turn. Provider lifecycle is supplied by the caller. */
export async function runOneRunAttempt(input: {
  readonly workerId: string;
  readonly leaseMs?: number;
  readonly execute: (attempt: ClaimedRunAttempt) => Promise<{ readonly providerVmId?: string | null; readonly result?: Record<string, unknown> }>;
}): Promise<RunAttemptWorkerResult> {
  const claimed = await claimNextRunAttempt(input);
  if (!claimed) return { status: "idle" };
  try {
    const result = await input.execute(claimed);
    const applied = await finishRunAttempt({ ...claimed, status: "succeeded", ...result });
    return { status: applied ? "succeeded" : "failed", runId: claimed.runId, attemptId: claimed.attemptId, applied };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const applied = await finishRunAttempt({ ...claimed, status: "failed", error: message });
    return { status: applied ? "failed" : "cancelled", runId: claimed.runId, attemptId: claimed.attemptId, applied };
  }
}

async function appendRunEvent(
  tx: CloudTransaction,
  runId: string,
  attemptId: string | null,
  kind: "attempt.started" | "attempt.succeeded" | "attempt.failed" | "attempt.cancelled" | "run.cancelled",
  payload: Record<string, unknown>,
): Promise<void> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run:${runId}`}, 0))`);
  await tx.execute(sql`
    insert into run_events (run_id, attempt_id, sequence, kind, payload)
    select ${runId}::uuid, ${attemptId ? sql`${attemptId}::uuid` : sql`null`}, coalesce(max(sequence), -1) + 1,
      ${kind}::run_event_kind, ${JSON.stringify(payload)}::jsonb
    from run_events where run_id = ${runId}::uuid
  `);
}
