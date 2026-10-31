import { and, asc, eq, gt, inArray, isNotNull, isNull, lt, or, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { cloudVms, runAttempts, runEvents, runs } from "../../../db/schema";
import {
  SANDBOX_ABANDONED_GRACE_MS,
  SANDBOX_QUEUED_ABANDON_MS,
  SANDBOX_VM_IDEMPOTENCY_PREFIX,
  SANDBOX_VM_MARKER_KEY,
  sandboxVmIdempotencyKey,
  type RunStatus,
  type SandboxRunOutcome,
} from "../model";
import { redactReceiptText, sandboxReply } from "../sandbox";
import { lockAttempt, lockRun, nextSequence, now, SERVER_EVENT_ID_PREFIX } from "./shared";
import { sandboxAttemptHandles, sandboxVmUnconfirmed } from "./sandboxVms";

/**
 * The launcher's view of a sandboxed Run (reply, exit code, boot time), written under the Run and
 * attempt locks and fenced on the lease the launcher still holds (token and generation, and a
 * live expiry unless the attempt is already terminal). A replacement lease, a cancel or the
 * abandoned sweep each change the token or generation, so a stale launcher writes nothing; the
 * current holder may correct its own earlier write. The reply is redacted here, while the
 * attempt still names its provider handles, so the stored text never holds them.
 */
export async function recordSandboxOutcome(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly outcome: SandboxRunOutcome;
}): Promise<boolean> {
  return cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.runId}, 0))`);
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    const nowAt = now();
    const attempt = (await tx.select().from(runAttempts).innerJoin(runs, eq(runs.id, runAttempts.runId)).where(and(
      eq(runAttempts.id, input.attemptId),
      eq(runAttempts.runId, input.runId),
      eq(runs.environment, "sandboxed"),
      eq(runAttempts.leaseToken, input.leaseToken),
      eq(runAttempts.leaseGeneration, input.leaseGeneration),
      // Once the reaper claimed the VM, the receipt is final.
      isNull(runAttempts.cleanupLeaseToken),
      or(
        inArray(runAttempts.status, ["succeeded", "failed", "cancelled"]),
        gt(runAttempts.leaseExpiresAt, nowAt),
      ),
    )).limit(1))[0]?.run_attempts;
    if (!attempt) return false;
    const { exitCode, signal, timedOut, bootMs } = input.outcome;
    const run = (await tx.select().from(runs).where(eq(runs.id, input.runId)).limit(1))[0];
    const handles = run ? await sandboxAttemptHandles(tx, run, attempt) : [attempt.providerVmId, attempt.providerWorkspaceId, attempt.providerTerminalId];
    const reply = input.outcome.reply === null ? null : sandboxReply(input.outcome.reply, handles);
    const error = input.outcome.error ? redactReceiptText(input.outcome.error, handles).slice(0, 500) : null;
    await tx.update(runs).set({ receipt: { reply, exitCode, signal, timedOut, bootMs, error }, updatedAt: nowAt }).where(eq(runs.id, input.runId));
    return true;
  });
}

type AbandonCutoffs = { readonly nowAt: Date; readonly leaseCutoff: Date; readonly queuedCutoff: Date };

/**
 * The reaper's backstop for a sandboxed Run whose launcher died (a deploy, a crash, the create
 * route's time budget). An attempt whose lease lapsed past the grace, or one never leased, is
 * failed with its VM due for destroy now, and the Run completes. A VM the launcher created but
 * never journaled is found by its create idempotency key, also after a cancel finished the
 * attempt first. Returns how many attempts it failed or VMs it adopted.
 */
export async function failAbandonedSandboxAttempts(input: { readonly now?: Date; readonly limit?: number; readonly runId?: string } = {}): Promise<number> {
  const nowAt = input.now ?? now();
  // Scoped to one Run (a cancel): only that Run's orphan VM; the live-attempt sweep stays the cron's.
  if (input.runId) return adoptOrphanSandboxVms(nowAt, input.limit, input.runId);
  const cutoffs: AbandonCutoffs = {
    nowAt,
    leaseCutoff: new Date(nowAt.getTime() - SANDBOX_ABANDONED_GRACE_MS),
    queuedCutoff: new Date(nowAt.getTime() - SANDBOX_QUEUED_ABANDON_MS),
  };
  const candidates = await cloudDb().select({ runId: runAttempts.runId, attemptId: runAttempts.id })
    .from(runAttempts).innerJoin(runs, eq(runs.id, runAttempts.runId)).where(and(
      eq(runs.environment, "sandboxed"),
      or(
        and(inArray(runAttempts.status, ["leased", "running"]), or(isNull(runAttempts.leaseExpiresAt), lt(runAttempts.leaseExpiresAt, cutoffs.leaseCutoff))),
        and(eq(runAttempts.status, "queued"), lt(runs.createdAt, cutoffs.queuedCutoff)),
      ),
    )).limit(Math.max(1, Math.min(input.limit ?? 20, 100)));
  let failed = 0;
  for (const candidate of candidates) {
    if (await failAbandonedSandboxAttempt(candidate.runId, candidate.attemptId, cutoffs)) failed += 1;
  }
  return failed + await adoptOrphanSandboxVms(nowAt, input.limit);
}

/** One adoption per attempt: a sandbox attempt only ever owns the one VM its create key names. */
const SANDBOX_VM_ADOPTED_EVENT = `${SERVER_EVENT_ID_PREFIX}sandbox-vm-adopted`;

/**
 * A finished sandbox attempt that names no VM while one created under its key is still up: the
 * launcher died between create and journal, and a cancel (or the sweep) finished the attempt
 * first. Record the VM for destroy now, journaled once per attempt (an opaque event id; the VM id
 * stays in the private payload), so a VM the reaper already cleared is never adopted again and
 * adopted rows never fill the batch ahead of a live orphan. No age cutoff: the obligation stays
 * until it is met; the batch limit and the partial sandbox index bound each pass.
 */
async function adoptOrphanSandboxVms(nowAt: Date, limit = 20, runId?: string): Promise<number> {
  const orphans = await cloudDb().select({ runId: runAttempts.runId, attemptId: runAttempts.id, providerVmId: cloudVms.providerVmId })
    .from(runAttempts)
    .innerJoin(runs, eq(runs.id, runAttempts.runId))
    .innerJoin(cloudVms, and(
      eq(cloudVms.billingTeamId, runs.billingTeamId),
      eq(cloudVms.userId, runs.userId),
      eq(cloudVms.idempotencyKey, sql`${SANDBOX_VM_IDEMPOTENCY_PREFIX} || ${runs.id}::text || ':attempt:' || ${runAttempts.id}::text`),
      // Only a VM the sandbox launcher marked: an unmarked row is an ordinary machine.
      sql`${cloudVms.providerMetadata}->>${SANDBOX_VM_MARKER_KEY} = ${cloudVms.idempotencyKey}`,
    ))
    .where(and(
      eq(runs.environment, "sandboxed"),
      ...(runId ? [eq(runs.id, runId)] : []),
      inArray(runs.status, ["succeeded", "failed", "cancelled"]),
      inArray(runAttempts.status, ["succeeded", "failed", "cancelled"]),
      isNull(runAttempts.providerVmId),
      isNotNull(cloudVms.providerVmId),
      // Any status: only a strict destroy's confirmation proves the machine is gone.
      sandboxVmUnconfirmed(),
      sql`not exists (select 1 from run_events where run_events.attempt_id = ${runAttempts.id} and run_events.external_id = ${SANDBOX_VM_ADOPTED_EVENT})`,
    )).orderBy(asc(runs.updatedAt)).limit(Math.max(1, Math.min(limit, 100)));
  let adopted = 0;
  for (const orphan of orphans) {
    if (!orphan.providerVmId) continue;
    const providerVmId = orphan.providerVmId;
    const done = await cloudDb().transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${orphan.runId}, 0))`);
      await lockRun(tx, orphan.runId);
      await lockAttempt(tx, orphan.runId, orphan.attemptId);
      const externalId = SANDBOX_VM_ADOPTED_EVENT;
      const seen = await tx.select({ id: runEvents.id }).from(runEvents).where(and(eq(runEvents.attemptId, orphan.attemptId), eq(runEvents.externalId, externalId))).limit(1);
      if (seen.length > 0) return false;
      const updated = await tx.update(runAttempts).set({ providerVmId, terminalRetainUntil: nowAt, updatedAt: nowAt }).where(and(
        eq(runAttempts.id, orphan.attemptId),
        isNull(runAttempts.providerVmId),
        isNull(runAttempts.cleanupLeaseToken),
        inArray(runAttempts.status, ["succeeded", "failed", "cancelled"]),
      )).returning({ id: runAttempts.id });
      if (updated.length === 0) return false;
      await tx.insert(runEvents).values({
        runId: orphan.runId,
        attemptId: orphan.attemptId,
        sequence: await nextSequence(tx, orphan.runId),
        externalId,
        kind: "attempt.heartbeat",
        payload: { providerVmId, reason: "sandbox_vm_adopted" },
      });
      return true;
    });
    if (done) adopted += 1;
  }
  return adopted;
}

function sandboxAttemptAbandoned(attempt: typeof runAttempts.$inferSelect, runCreatedAt: Date, cutoffs: AbandonCutoffs): boolean {
  if (attempt.status === "queued") return runCreatedAt.getTime() < cutoffs.queuedCutoff.getTime();
  if (attempt.status !== "leased" && attempt.status !== "running") return false;
  return !attempt.leaseExpiresAt || attempt.leaseExpiresAt.getTime() < cutoffs.leaseCutoff.getTime();
}

async function failAbandonedSandboxAttempt(runId: string, attemptId: string, cutoffs: AbandonCutoffs): Promise<boolean> {
  return cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${runId}, 0))`);
    await lockRun(tx, runId);
    await lockAttempt(tx, runId, attemptId);
    const row = (await tx.select({ attempt: runAttempts, run: runs }).from(runAttempts)
      .innerJoin(runs, eq(runs.id, runAttempts.runId))
      .where(and(eq(runAttempts.id, attemptId), eq(runs.environment, "sandboxed"))).limit(1))[0];
    if (!row || !sandboxAttemptAbandoned(row.attempt, row.run.createdAt, cutoffs)) return false;
    const nowAt = cutoffs.nowAt;
    const orphanVmId = row.attempt.providerVmId || !row.run.billingTeamId ? null : (await tx.select({ providerVmId: cloudVms.providerVmId }).from(cloudVms).where(and(
      eq(cloudVms.billingTeamId, row.run.billingTeamId),
      eq(cloudVms.idempotencyKey, sandboxVmIdempotencyKey(runId, attemptId)),
      sql`${cloudVms.providerMetadata}->>${SANDBOX_VM_MARKER_KEY} = ${sandboxVmIdempotencyKey(runId, attemptId)}`,
      isNotNull(cloudVms.providerVmId),
      sandboxVmUnconfirmed(),
    )).limit(1))[0]?.providerVmId ?? null;
    const providerVmId = row.attempt.providerVmId ?? orphanVmId;
    const cancelling = row.run.status === "cancelling";
    const error = "the sandbox controller stopped before the run finished";
    await tx.update(runAttempts).set({
      status: cancelling ? "cancelled" : "failed",
      error,
      providerVmId,
      leaseToken: null,
      leaseExpiresAt: null,
      leaseGeneration: sql`${runAttempts.leaseGeneration} + 1`,
      finishedAt: nowAt,
      terminalRetainUntil: providerVmId ? nowAt : null,
      updatedAt: nowAt,
    }).where(eq(runAttempts.id, attemptId));
    await tx.insert(runEvents).values({
      runId,
      attemptId,
      sequence: await nextSequence(tx, runId),
      externalId: `${SERVER_EVENT_ID_PREFIX}sandbox-abandoned:${row.attempt.leaseGeneration}`,
      kind: "attempt.failed",
      payload: { reason: "controller_lost", ...(providerVmId ? { providerVmId } : {}) },
    }).onConflictDoNothing();
    const active = await tx.select({ id: runAttempts.id }).from(runAttempts).where(and(
      eq(runAttempts.runId, runId),
      inArray(runAttempts.status, ["queued", "leased", "running"]),
    )).limit(1);
    if (active.length === 0) {
      const finalStatus: RunStatus = cancelling ? "cancelled" : "failed";
      const completed = (await tx.update(runs).set({ status: finalStatus, error: cancelling ? null : error, completedAt: nowAt, updatedAt: nowAt }).where(and(
        eq(runs.id, runId),
        inArray(runs.status, ["queued", "running", "cancelling"]),
      )).returning())[0];
      if (completed) {
        await tx.insert(runEvents).values({
          runId,
          sequence: await nextSequence(tx, runId),
          externalId: "run-completed",
          kind: "run.completed",
          payload: { status: finalStatus },
        });
      }
    }
    return true;
  });
}
