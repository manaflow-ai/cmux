import { and, eq, inArray, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { runAttempts, runEvents, runs } from "../../../db/schema";
import { lockAttempt, lockRun, nextSequence, now, RunAttemptNotFoundError, RunNotFoundError, terminalRetentionMs } from "./shared";
import { readSnapshot, type RunSnapshot } from "./run";

export async function cancelRun(runId: string, userId: string): Promise<RunSnapshot> {
  const db = cloudDb();
  return db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${runId}, 0))`);
    const run = (await tx.update(runs).set({ status: "cancelling", cancelRequestedAt: now(), updatedAt: now() }).where(and(
      eq(runs.id, runId), eq(runs.userId, userId), inArray(runs.status, ["queued", "running"]),
    )).returning())[0];
    if (!run) {
      const existing = (await tx.select().from(runs).where(and(eq(runs.id, runId), eq(runs.userId, userId))).limit(1))[0];
      if (!existing) throw new RunNotFoundError("run not found");
      return readSnapshot(tx, runId, userId);
    }
    await tx.update(runAttempts).set({ status: "cancelled", leaseToken: null, leaseExpiresAt: null, updatedAt: now() }).where(and(eq(runAttempts.runId, runId), eq(runAttempts.status, "queued")));
    const sequence = await nextSequence(tx, runId);
    await tx.insert(runEvents).values({ runId, sequence, externalId: `cancel-${runId}`, kind: "run.cancel_requested", payload: {} });
    const active = await tx.select({ id: runAttempts.id }).from(runAttempts).where(and(eq(runAttempts.runId, runId), inArray(runAttempts.status, ["leased", "running"]))).limit(1);
    if (active.length === 0) {
      await tx.update(runs).set({ status: "cancelled", completedAt: now(), updatedAt: now() }).where(eq(runs.id, runId));
      await tx.insert(runEvents).values({ runId, sequence: await nextSequence(tx, runId), externalId: `run-completed-${runId}`, kind: "run.completed", payload: { status: "cancelled" } });
    }
    return readSnapshot(tx, runId, userId);
  });
}

/** Active provider handles that a cancellation worker should close. */
export async function listActiveCloudVmAttempts(runId: string, userId: string) {
  const rows = await cloudDb().select({
    attempt: runAttempts,
    userId: runs.userId,
    billingTeamId: runs.billingTeamId,
  }).from(runAttempts).innerJoin(runs, eq(runs.id, runAttempts.runId)).where(and(
    eq(runAttempts.runId, runId),
    eq(runs.userId, userId),
    inArray(runAttempts.status, ["leased", "running"]),
  ));
  if (rows.length === 0) {
    const visible = await cloudDb().select({ id: runs.id }).from(runs).where(and(eq(runs.id, runId), eq(runs.userId, userId))).limit(1);
    if (visible.length === 0) throw new RunNotFoundError("run not found");
  }
  return rows;
}

/** Fence a cancelled worker and complete the Run when no active attempt remains. */
export async function finalizeAttemptCancellation(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly leaseToken?: string | null;
  readonly leaseGeneration?: number | null;
}): Promise<typeof runAttempts.$inferSelect> {
  return cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.runId}, 0))`);
    await lockRun(tx, input.runId);
    await lockAttempt(tx, input.runId, input.attemptId);
    const current = (await tx.select().from(runAttempts).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId))).limit(1))[0];
    if (!current) throw new RunAttemptNotFoundError("attempt not found");
    const environment = (await tx.select({ environment: runs.environment }).from(runs).where(eq(runs.id, input.runId)).limit(1))[0]?.environment;
    const isActive = ["queued", "leased", "running"].includes(current.status);
    let attempt = current;
    if (isActive) {
      const conditions = [eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId)];
      if (input.leaseToken) conditions.push(eq(runAttempts.leaseToken, input.leaseToken));
      if (input.leaseGeneration !== undefined && input.leaseGeneration !== null) conditions.push(eq(runAttempts.leaseGeneration, input.leaseGeneration));
      attempt = (await tx.update(runAttempts).set({
        status: "cancelled",
        leaseToken: null,
        leaseExpiresAt: null,
        leaseGeneration: sql`${runAttempts.leaseGeneration} + 1`,
        finishedAt: now(),
        terminalRetainUntil: current.providerVmId ? new Date(Date.now() + terminalRetentionMs(environment)) : null,
        updatedAt: now(),
      }).where(and(...conditions)).returning())[0] ?? current;
    }
    const active = await tx.select({ id: runAttempts.id }).from(runAttempts).where(and(
      eq(runAttempts.runId, input.runId),
      inArray(runAttempts.status, ["queued", "leased", "running"]),
    )).limit(1);
    if (active.length === 0) {
      const completed = (await tx.update(runs).set({ status: "cancelled", completedAt: now(), updatedAt: now() }).where(and(eq(runs.id, input.runId), eq(runs.status, "cancelling"))).returning())[0];
      if (completed) {
        await tx.insert(runEvents).values({
          runId: input.runId,
          sequence: await nextSequence(tx, input.runId),
          externalId: "run-completed",
          kind: "run.completed",
          payload: { status: "cancelled" },
        });
      }
    }
    return attempt;
  });
}

/** Final safety net for a cancellation request whose provider worker vanished. */
export async function forceFinalizeRunCancellation(runId: string, userId: string): Promise<void> {
  await cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${runId}, 0))`);
    const run = (await tx.select({ status: runs.status, environment: runs.environment }).from(runs).where(and(eq(runs.id, runId), eq(runs.userId, userId))).for("update").limit(1))[0];
    if (!run) throw new RunNotFoundError("run not found");
    if (run.status !== "cancelling") return;
    const retention = run.environment === "sandboxed" ? sql`now()` : sql`now() + interval '10 minutes'`;
    await tx.update(runAttempts).set({
      status: "cancelled",
      leaseToken: null,
      leaseExpiresAt: null,
      leaseGeneration: sql`${runAttempts.leaseGeneration} + 1`,
      finishedAt: now(),
      terminalRetainUntil: sql`case when ${runAttempts.providerVmId} is null then null else coalesce(${runAttempts.terminalRetainUntil}, ${retention}) end`,
      updatedAt: now(),
    }).where(and(eq(runAttempts.runId, runId), inArray(runAttempts.status, ["queued", "leased", "running"])));
    const completed = (await tx.update(runs).set({ status: "cancelled", completedAt: now(), updatedAt: now() }).where(and(eq(runs.id, runId), eq(runs.status, "cancelling"))).returning())[0];
    if (completed) {
      await tx.insert(runEvents).values({
        runId,
        sequence: await nextSequence(tx, runId),
        externalId: "run-completed",
        kind: "run.completed",
        payload: { status: "cancelled" },
      });
    }
  });
}
