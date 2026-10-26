import { randomUUID } from "node:crypto";
import { sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { canApplyRunAttemptMutation, isRunAttemptLeaseActive, runAttemptTransitionDecision, type RunAttemptTerminalStatus } from "./worker-contract";

export { canApplyRunAttemptMutation, isRunAttemptLeaseActive, runAttemptTransitionDecision };

export type ClaimedRunAttempt = {
  readonly runId: string;
  readonly userId: string;
  readonly ownerTeamId: string | null;
  readonly attemptId: string;
  readonly ordinal: number;
  readonly variant: Record<string, unknown>;
  readonly spec: Record<string, unknown>;
  readonly checkpoint: Record<string, unknown> | null;
  readonly retainedUntil: Date | null;
  readonly cleanupState: string | null;
  readonly leaseId: string;
  readonly leaseUntil: Date;
  readonly workerId: string;
  /** First claim time; bounds how long an in-progress VM create is retried. */
  readonly startedAt: Date | null;
};

export type RunAttemptWorkerResult =
  | { readonly status: "idle" }
  | { readonly status: "succeeded" | "failed" | "cancelled"; readonly runId: string; readonly attemptId: string; readonly applied: boolean };

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
  const raw = row[key];
  const value = typeof raw === "string" ? JSON.parse(raw) as unknown : raw;
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`Run attempt query returned invalid ${key}`);
  return value as Record<string, unknown>;
}

function optionalRowRecord(value: unknown): Record<string, unknown> | null {
  const parsed = typeof value === "string" ? JSON.parse(value) as unknown : value;
  return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : null;
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
  readonly runId?: string;
  readonly ownerUserId?: string;
  readonly ownerTeamId?: string;
}): Promise<ClaimedRunAttempt | null> {
  const now = input.now ?? new Date();
  const leaseUntil = new Date(now.getTime() + boundedLeaseMs(input.leaseMs));
  const leaseId = randomUUID();
  return await cloudDb().transaction(async (tx) => {
    // Choose a run without locking first. The per-run advisory lock is always
    // acquired before an attempt row lock, matching cancellation/completion.
    const candidates = await tx.execute(sql`
      select a.run_id::text, a.id::text
      from run_attempts a
      join runs r on r.id = a.run_id
      where r.status in ('queued', 'running')
        and r.spec is not null
        ${input.runId ? sql`and a.run_id = ${input.runId}::uuid` : sql``}
        ${input.ownerUserId ? sql`and r.user_id = ${input.ownerUserId}` : sql``}
        ${input.ownerTeamId ? sql`and r.owner_team_id = ${input.ownerTeamId}` : sql``}
        and a.cancel_requested_at is null
        and (
          select count(*) from run_attempts active
          where active.run_id = a.run_id
            and active.status = 'running'
            and active.lease_until > ${now.toISOString()}::timestamptz
        ) < coalesce(nullif(r.spec #>> '{resources,maxConcurrent}', '')::integer, 1)
        and (
          a.status = 'queued'
          or (a.status = 'running' and (a.lease_until is null or a.lease_until <= ${now.toISOString()}::timestamptz))
        )
      order by a.created_at asc, a.ordinal asc, a.id asc
      limit 1
    `) as readonly Record<string, unknown>[];
    const candidate = candidates[0];
    if (!candidate) return null;
    const runId = rowString(candidate, "run_id");
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run:${runId}`}, 0))`);
    const rows = await tx.execute(sql`
      with candidate as (
        select a.id, r.user_id, r.owner_team_id, r.spec
        from run_attempts a
        join runs r on r.id = a.run_id
        where a.run_id = ${runId}::uuid
          and r.status in ('queued', 'running')
          and r.spec is not null
          ${input.runId ? sql`and a.run_id = ${input.runId}::uuid` : sql``}
          ${input.ownerUserId ? sql`and r.user_id = ${input.ownerUserId}` : sql``}
          ${input.ownerTeamId ? sql`and r.owner_team_id = ${input.ownerTeamId}` : sql``}
          and a.cancel_requested_at is null
          and (
            select count(*) from run_attempts active
            where active.run_id = a.run_id
              and active.status = 'running'
              and active.lease_until > ${now.toISOString()}::timestamptz
          ) < coalesce(nullif(r.spec #>> '{resources,maxConcurrent}', '')::integer, 1)
          and (
            a.status = 'queued'
            or (a.status = 'running' and (a.lease_until is null or a.lease_until <= ${now.toISOString()}::timestamptz))
          )
        order by a.created_at asc, a.ordinal asc, a.id asc
        for update of a skip locked
        limit 1
      )
      update run_attempts a
      set status = 'running',
          lease_id = ${leaseId}::uuid,
          lease_until = ${leaseUntil.toISOString()}::timestamptz,
          worker_id = ${input.workerId},
          started_at = coalesce(a.started_at, ${now.toISOString()}::timestamptz),
          updated_at = ${now.toISOString()}::timestamptz
      from candidate
      where a.id = candidate.id
      returning a.run_id::text, a.id::text, a.ordinal, a.variant,
        a.lease_id::text, a.lease_until, a.worker_id,
        a.checkpoint, a.retained_until, a.cleanup_state, a.started_at,
        candidate.user_id, candidate.owner_team_id, candidate.spec
    `) as readonly Record<string, unknown>[];
    const row = rows[0];
    if (!row) return null;
    const claimed = {
      runId: rowString(row, "run_id"),
      userId: rowString(row, "user_id"),
      ownerTeamId: typeof row.owner_team_id === "string" ? row.owner_team_id : null,
      attemptId: rowString(row, "id"),
      ordinal: Number(row.ordinal),
      variant: rowRecord(row, "variant"),
      spec: rowRecord(row, "spec"),
      checkpoint: optionalRowRecord(row.checkpoint),
      retainedUntil: row.retained_until ? rowDate(row, "retained_until") : null,
      cleanupState: typeof row.cleanup_state === "string" ? row.cleanup_state : null,
      leaseId: rowString(row, "lease_id"),
      leaseUntil: rowDate(row, "lease_until"),
      workerId: rowString(row, "worker_id"),
      startedAt: row.started_at ? rowDate(row, "started_at") : null,
    } satisfies ClaimedRunAttempt;
    await tx.execute(sql`update runs set status = 'running', updated_at = ${now.toISOString()}::timestamptz where id = ${claimed.runId}::uuid and status <> 'cancelled'`);
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
  return await cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run:${input.runId}`}, 0))`);
    const rows = await tx.execute(sql`
      update run_attempts
      set lease_until = ${leaseUntil.toISOString()}::timestamptz, updated_at = ${now.toISOString()}::timestamptz
      where run_id = ${input.runId}::uuid and id = ${input.attemptId}::uuid
        and status = 'running' and lease_id = ${input.leaseId}::uuid
        and lease_until > ${now.toISOString()}::timestamptz
        and cancel_requested_at is null
      returning id
    `) as readonly Record<string, unknown>[];
    return rows.length > 0;
  });
}

/** A Date bound into raw `sql` reaches postgres.js as a Date, and drizzle's
 * postgres-js driver turns off the timestamptz serializer, so the Bind step
 * throws ERR_INVALID_ARG_TYPE. Pass an ISO string and cast it in SQL instead,
 * like every `now` parameter in this file. */
function timestamptzParam(value: Date | null | undefined): string | null {
  return value ? value.toISOString() : null;
}

/** Persist provider progress while retaining the same lease fence. */
export async function checkpointRunAttempt(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseId: string;
  readonly checkpoint: Record<string, unknown>;
  readonly providerVmId?: string | null;
  readonly cleanupState?: string | null;
  readonly retainedUntil?: Date | null;
  readonly now?: Date;
}): Promise<boolean> {
  const now = input.now ?? new Date();
  return await cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run:${input.runId}`}, 0))`);
    const rows = await tx.execute(sql`
      update run_attempts
      set provider_vm_id = coalesce(${input.providerVmId ?? null}, provider_vm_id),
          checkpoint = ${JSON.stringify(input.checkpoint)}::jsonb,
          cleanup_state = coalesce(${input.cleanupState ?? null}, cleanup_state),
          retained_until = coalesce(${timestamptzParam(input.retainedUntil)}::timestamptz, retained_until),
          updated_at = ${now.toISOString()}::timestamptz
      where run_id = ${input.runId}::uuid and id = ${input.attemptId}::uuid
        and status = 'running' and lease_id = ${input.leaseId}::uuid
        and lease_until > ${now.toISOString()}::timestamptz and cancel_requested_at is null
      returning id
    `) as readonly Record<string, unknown>[];
    return rows.length > 0;
  });
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
  readonly checkpoint?: Record<string, unknown> | null;
  readonly cleanupState?: string | null;
  readonly retainedUntil?: Date | null;
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
  readonly checkpoint?: Record<string, unknown> | null;
  readonly cleanupState?: string | null;
  readonly retainedUntil?: Date | null;
  readonly error?: string | null;
  readonly now?: Date;
}): Promise<boolean> {
  const now = input.now ?? new Date();
  return await cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run:${input.runId}`}, 0))`);
    const rows = await tx.execute(sql`
      update run_attempts
      set status = ${input.status}::run_attempt_status,
          provider_vm_id = coalesce(${input.providerVmId ?? null}, provider_vm_id),
          result = coalesce(${input.result ? JSON.stringify(input.result) : null}::jsonb, result),
          checkpoint = coalesce(${input.checkpoint ? JSON.stringify(input.checkpoint) : null}::jsonb, checkpoint),
          cleanup_state = coalesce(${input.cleanupState ?? null}, cleanup_state),
          retained_until = coalesce(${timestamptzParam(input.retainedUntil)}::timestamptz, retained_until),
          error = ${input.error?.slice(0, 1_000) ?? null},
          finished_at = ${now.toISOString()}::timestamptz, lease_until = null, updated_at = ${now.toISOString()}::timestamptz
      where run_id = ${input.runId}::uuid and id = ${input.attemptId}::uuid
        and status = 'running' and lease_id = ${input.leaseId}::uuid
        and lease_until > ${now.toISOString()}::timestamptz
        and ${input.status === "cancelled" ? sql`true` : sql`cancel_requested_at is null`}
        ${input.status === "cancelled" ? sql`` : sql`and exists (select 1 from runs where id = ${input.runId}::uuid and status <> 'cancelled')`}
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
      completed_at = case when not exists (select 1 from run_attempts where run_id = ${input.runId}::uuid and status in ('queued', 'running')) then ${now.toISOString()}::timestamptz else completed_at end,
      updated_at = ${now.toISOString()}::timestamptz
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
    if (runRows.length === 0 || (runRows[0]?.status !== "queued" && runRows[0]?.status !== "running")) return false;
    const queued = await tx.execute(sql`
      update run_attempts set status = 'cancelled', finished_at = ${now.toISOString()}::timestamptz, updated_at = ${now.toISOString()}::timestamptz
      where run_id = ${input.runId}::uuid and status = 'queued'
      returning id::text
    `) as readonly Record<string, unknown>[];
    await tx.execute(sql`
      update run_attempts set cancel_requested_at = ${now.toISOString()}::timestamptz, updated_at = ${now.toISOString()}::timestamptz
      where run_id = ${input.runId}::uuid and status = 'running'
    `);
    await tx.execute(sql`update runs set status = 'cancelled', completed_at = ${now.toISOString()}::timestamptz, updated_at = ${now.toISOString()}::timestamptz where id = ${input.runId}::uuid`);
    for (const row of queued) {
      await appendRunEvent(tx, input.runId, rowString(row, "id"), "attempt.cancelled", { reason: "run_cancelled" });
    }
    await appendRunEvent(tx, input.runId, null, "run.cancelled", { cancelledQueuedAttempts: queued.length });
    return true;
  });
}

/**
 * Finishes cancellation for workers that disappeared after a cancellation
 * request. Each turn handles a bounded number and uses the same run-before-
 * attempt lock order as claim/finish, so cleanup can safely run concurrently.
 */
export async function reconcileCancelledRunAttempts(input: { readonly limit?: number; readonly now?: Date } = {}): Promise<number> {
  const limit = Math.max(1, Math.min(Math.trunc(input.limit ?? 100), 500));
  const now = input.now ?? new Date();
  let reconciled = 0;
  for (let index = 0; index < limit; index += 1) {
    const changed = await cloudDb().transaction(async (tx) => {
      const candidates = await tx.execute(sql`
        select a.run_id::text, a.id::text
        from run_attempts a
        where a.status = 'running'
          and a.cancel_requested_at is not null
          and (a.lease_until is null or a.lease_until <= ${now.toISOString()}::timestamptz)
        order by a.cancel_requested_at asc, a.id asc
        limit 1
      `) as readonly Record<string, unknown>[];
      const candidate = candidates[0];
      if (!candidate) return false;
      const runId = rowString(candidate, "run_id");
      const attemptId = rowString(candidate, "id");
      // Acquire the run fence before the attempt mutation so cancellation and
      // terminal callbacks share lock order.
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run:${runId}`}, 0))`);
      const rows = await tx.execute(sql`
        update run_attempts
        set status = 'cancelled', finished_at = ${now.toISOString()}::timestamptz, lease_id = null,
            lease_until = null, worker_id = null, updated_at = ${now.toISOString()}::timestamptz
        where run_id = ${runId}::uuid and id = ${attemptId}::uuid
          and status = 'running' and cancel_requested_at is not null
        returning id
      `) as readonly Record<string, unknown>[];
      if (rows.length === 0) return false;
      await appendRunEvent(tx, runId, attemptId, "attempt.cancelled", { reason: "worker_lease_expired" });
      return true;
    });
    if (!changed) break;
    reconciled += 1;
  }
  return reconciled;
}

/** One bounded worker turn. Provider lifecycle is supplied by the caller. */
export async function runOneRunAttempt(input: {
  readonly workerId: string;
  readonly leaseMs?: number;
  readonly execute: (attempt: ClaimedRunAttempt) => Promise<{
    readonly providerVmId?: string | null;
    readonly result?: Record<string, unknown>;
    readonly checkpoint?: Record<string, unknown> | null;
    readonly cleanupState?: string | null;
    readonly retainedUntil?: Date | null;
  }>;
}): Promise<RunAttemptWorkerResult> {
  const claimed = await claimNextRunAttempt(input);
  if (!claimed) return { status: "idle" };
  try {
    const result = await input.execute(claimed);
    const applied = await finishRunAttempt({ ...claimed, status: "succeeded", ...result });
    return { status: applied ? "succeeded" : "cancelled", runId: claimed.runId, attemptId: claimed.attemptId, applied };
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
