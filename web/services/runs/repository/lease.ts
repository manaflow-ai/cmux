import { randomUUID } from "node:crypto";
import { and, eq, gt, inArray, isNull, lt, or, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { runAttempts, runEvents, runs } from "../../../db/schema";
import { DEFAULT_LEASE_TTL_MS, DEFAULT_TERMINAL_RETENTION_MS } from "../model";
import { lockAttempt, lockRun, nextSequence, now, RunLeaseConflictError, type RunQueryDb } from "./shared";

export type AttemptLease = {
  readonly attempt: typeof runAttempts.$inferSelect;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly leaseExpiresAt: Date;
};

export async function claimAttemptLease(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly workerId: string;
  readonly ttlMs?: number;
}): Promise<AttemptLease> {
  const ttlMs = Math.max(5_000, Math.min(input.ttlMs ?? DEFAULT_LEASE_TTL_MS, 15 * 60_000));
  const nowAt = now();
  const expiresAt = new Date(nowAt.getTime() + ttlMs);
  const token = randomUUID();
  return cloudDb().transaction(async (tx) => {
    const run = (await tx.select({ status: runs.status }).from(runs).where(eq(runs.id, input.runId)).for("update").limit(1))[0];
    if (!run || run.status === "cancelling" || run.status === "cancelled" || run.status === "succeeded" || run.status === "failed") {
      throw new RunLeaseConflictError("run is not accepting new attempt leases");
    }
    const rows = await tx.update(runAttempts).set({
    status: "leased",
    leaseToken: token,
    leaseGeneration: sql`${runAttempts.leaseGeneration} + 1`,
    leaseExpiresAt: expiresAt,
    updatedAt: nowAt,
    }).where(and(
    eq(runAttempts.id, input.attemptId),
    eq(runAttempts.runId, input.runId),
    or(
      eq(runAttempts.status, "queued"),
      and(
        inArray(runAttempts.status, ["leased", "running"]),
        or(isNull(runAttempts.leaseExpiresAt), lt(runAttempts.leaseExpiresAt, nowAt)),
      ),
    ),
    )).returning();
    const attempt = rows[0];
    if (!attempt) throw new RunLeaseConflictError("attempt is already leased or does not exist");
    await tx.update(runs).set({ status: "running", updatedAt: nowAt }).where(and(eq(runs.id, input.runId), eq(runs.status, "queued")));
    return { attempt, leaseToken: token, leaseGeneration: attempt.leaseGeneration, leaseExpiresAt: expiresAt };
  });
}

export async function renewAttemptLease(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly ttlMs?: number;
}): Promise<AttemptLease> {
  const nowAt = now();
  const expiresAt = new Date(nowAt.getTime() + Math.max(5_000, Math.min(input.ttlMs ?? DEFAULT_LEASE_TTL_MS, 15 * 60_000)));
  const attempt = (await cloudDb().update(runAttempts).set({
    leaseExpiresAt: expiresAt,
    updatedAt: nowAt,
  }).where(and(
    eq(runAttempts.id, input.attemptId),
    eq(runAttempts.runId, input.runId),
    eq(runAttempts.leaseToken, input.leaseToken),
    eq(runAttempts.leaseGeneration, input.leaseGeneration),
    inArray(runAttempts.status, ["leased", "running"]),
    gt(runAttempts.leaseExpiresAt, nowAt),
  )).returning())[0];
  if (!attempt) throw new RunLeaseConflictError("stale or expired attempt lease");
  return { attempt, leaseToken: input.leaseToken, leaseGeneration: input.leaseGeneration, leaseExpiresAt: expiresAt };
}

/** Persist the provider handles before a worker starts streaming terminal events. */
export async function recordAttemptProviderHandle(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly providerVmId: string;
  readonly providerWorkspaceId: string;
  readonly providerTerminalId: string;
}): Promise<typeof runAttempts.$inferSelect> {
  const db = cloudDb();
  return db.transaction(async (tx) => {
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    await checkLease(tx, input);
    const attempt = (await tx.update(runAttempts).set({
      providerVmId: input.providerVmId,
      providerWorkspaceId: input.providerWorkspaceId,
      providerTerminalId: input.providerTerminalId,
      updatedAt: now(),
    }).where(and(
      eq(runAttempts.id, input.attemptId),
      eq(runAttempts.runId, input.runId),
      eq(runAttempts.leaseToken, input.leaseToken),
      eq(runAttempts.leaseGeneration, input.leaseGeneration),
    )).returning())[0];
    if (!attempt) throw new RunLeaseConflictError("stale or expired attempt lease");
    return attempt;
  });
}

/** Keep a provider VM around after a terminal event so the terminal can be attached. */
export async function scheduleAttemptRetention(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken: string;
  readonly leaseGeneration: number;
  readonly providerVmId?: string;
  readonly retentionMs?: number;
}): Promise<typeof runAttempts.$inferSelect> {
  const retentionMs = Math.max(0, Math.min(input.retentionMs ?? DEFAULT_TERMINAL_RETENTION_MS, 60 * 60_000));
  const attempt = (await cloudDb().update(runAttempts).set({
    ...(input.providerVmId ? { providerVmId: input.providerVmId } : {}),
    terminalRetainUntil: new Date(Date.now() + retentionMs),
    cleanupLeaseToken: null,
    cleanupLeaseExpiresAt: null,
    leaseToken: null,
    leaseExpiresAt: null,
    updatedAt: now(),
  }).where(and(
    eq(runAttempts.id, input.attemptId),
    eq(runAttempts.runId, input.runId),
    eq(runAttempts.leaseToken, input.leaseToken),
    eq(runAttempts.leaseGeneration, input.leaseGeneration),
    inArray(runAttempts.status, ["succeeded", "failed", "cancelled"]),
  )).returning())[0];
  if (attempt) return attempt;
  if (input.providerVmId) {
    const orphan = await adoptFencedAttemptVm({ ...input, providerVmId: input.providerVmId });
    if (orphan) return orphan;
  }
  throw new RunLeaseConflictError("stale or expired attempt lease");
}

/**
 * A cancel (or a replacement lease) can fence a worker while its createVm is
 * still in flight. That worker then learns the VM id only after it can no
 * longer write, so no row would point at the VM and the reaper would never
 * destroy it. Record the id for immediate cleanup, but only when no lease ever
 * stored a VM for this attempt: then nothing else owns the VM (the create is
 * idempotent per attempt), and a VM the reaper already destroyed and cleared
 * is never handed back to it. The fenced worker's other state is not written.
 *
 * A retention deadline alone does not mean a VM exists: a replacement lease
 * that fails the attempt before creating one also sets it. Adoption therefore
 * ignores the deadline and keys "nothing to reap" on the VM id and on the
 * journal, and it journals the adopted id itself so that a VM it handed to the
 * reaper, once destroyed and cleared, cannot be adopted a second time. A
 * terminal status means no live lease owns the attempt, and a promoted VM is
 * always recorded on the row or in the journal, so neither can be adopted.
 */
async function adoptFencedAttemptVm(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseGeneration: number;
  readonly providerVmId: string;
}): Promise<typeof runAttempts.$inferSelect | undefined> {
  return cloudDb().transaction(async (tx) => {
    // Same lock order as ingestRunEvent, which allocates journal sequences.
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.runId}, 0))`);
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    const nowAt = now();
    const adopted = (await tx.update(runAttempts).set({
      providerVmId: input.providerVmId,
      terminalRetainUntil: nowAt,
      cleanupLeaseToken: null,
      cleanupLeaseExpiresAt: null,
      updatedAt: nowAt,
    }).where(and(
      eq(runAttempts.id, input.attemptId),
      eq(runAttempts.runId, input.runId),
      gt(runAttempts.leaseGeneration, input.leaseGeneration),
      inArray(runAttempts.status, ["succeeded", "failed", "cancelled"]),
      isNull(runAttempts.providerVmId),
      isNull(runAttempts.cleanupLeaseToken),
      sql`not exists (select 1 from run_events where run_events.attempt_id = ${input.attemptId} and run_events.payload->>'providerVmId' is not null)`,
    )).returning())[0];
    if (!adopted) return undefined;
    await tx.insert(runEvents).values({
      runId: input.runId,
      attemptId: input.attemptId,
      sequence: await nextSequence(tx, input.runId),
      externalId: `provider-vm-adopted:${input.leaseGeneration}`,
      kind: "attempt.heartbeat",
      payload: { providerVmId: input.providerVmId, adoptedFromLeaseGeneration: input.leaseGeneration },
    });
    return adopted;
  });
}

export type LeaseInput = { readonly runId: string; readonly attemptId: string; readonly leaseToken: string; readonly leaseGeneration: number };

export async function findLiveLease(db: RunQueryDb, input: LeaseInput): Promise<typeof runAttempts.$inferSelect | undefined> {
  return (await db.select().from(runAttempts).where(and(
    eq(runAttempts.id, input.attemptId),
    eq(runAttempts.runId, input.runId),
    eq(runAttempts.leaseToken, input.leaseToken),
    eq(runAttempts.leaseGeneration, input.leaseGeneration),
    inArray(runAttempts.status, ["leased", "running"]),
    gt(runAttempts.leaseExpiresAt, now()),
  )).limit(1))[0];
}

export async function checkLease(db: RunQueryDb, input: LeaseInput): Promise<typeof runAttempts.$inferSelect> {
  const attempt = await findLiveLease(db, input);
  if (!attempt) throw new RunLeaseConflictError("stale or expired attempt lease");
  return attempt;
}
