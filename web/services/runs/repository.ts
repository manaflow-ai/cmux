import { and, asc, desc, eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { runAttempts, runEvents, runs } from "../../db/schema";
import type { RunSpec } from "./spec";

export type RunSnapshot = {
  readonly run: typeof runs.$inferSelect;
  readonly attempts: ReadonlyArray<typeof runAttempts.$inferSelect>;
  readonly events: ReadonlyArray<typeof runEvents.$inferSelect>;
};

export async function createRunRecord(input: {
  readonly userId: string;
  readonly billingTeamId: string | null;
  readonly idempotencyKey: string;
  readonly requestDigest: string;
  readonly spec: RunSpec;
}): Promise<{ readonly snapshot: RunSnapshot; readonly reused: boolean }> {
  const db = cloudDb();
  const existing = await db.select().from(runs).where(and(
    eq(runs.userId, input.userId),
    eq(runs.idempotencyKey, input.idempotencyKey),
  )).limit(1);
  if (existing[0]) {
    if (existing[0].requestDigest !== input.requestDigest) {
      throw new RunIdempotencyConflictError();
    }
    return { snapshot: await readRunSnapshot(existing[0].id, input.userId) as RunSnapshot, reused: true };
  }

  const snapshot = await db.transaction(async (tx) => {
    const [run] = await tx.insert(runs).values({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      idempotencyKey: input.idempotencyKey,
      requestDigest: input.requestDigest,
      source: input.spec.source,
      recipe: input.spec.recipe.id,
      provider: "cloud-vm",
      desiredAttempts: input.spec.variants.length,
      maxConcurrent: input.spec.resources.maxConcurrent,
      status: "queued",
    }).returning();
    if (!run) throw new Error("run insert returned no row");
    const attempts = await tx.insert(runAttempts).values(input.spec.variants.map((variant, ordinal) => ({
      runId: run.id,
      ordinal,
      variant,
      status: "queued" as const,
    }))).returning();
    const eventValues = [
      { runId: run.id, sequence: 0, kind: "run.created" as const, payload: { requestDigest: input.requestDigest, desiredAttempts: attempts.length } },
      ...attempts.map((attempt, index) => ({
        runId: run.id,
        attemptId: attempt.id,
        sequence: index + 1,
        kind: "attempt.queued" as const,
        payload: { ordinal: attempt.ordinal, variantId: input.spec.variants[attempt.ordinal]?.id ?? "" },
      })),
    ];
    await tx.insert(runEvents).values(eventValues);
    return { run, attempts };
  });
  return {
    snapshot: { run: snapshot.run, attempts: snapshot.attempts, events: [] },
    reused: false,
  };
}

export class RunIdempotencyConflictError extends Error {
  override readonly name = "RunIdempotencyConflictError";
}

export async function readRunSnapshot(runId: string, userId: string): Promise<RunSnapshot | null> {
  const [run] = await cloudDb().select().from(runs).where(and(eq(runs.id, runId), eq(runs.userId, userId))).limit(1);
  if (!run) return null;
  const [attempts, events] = await Promise.all([
    cloudDb().select().from(runAttempts).where(eq(runAttempts.runId, run.id)).orderBy(asc(runAttempts.ordinal)),
    cloudDb().select().from(runEvents).where(eq(runEvents.runId, run.id)).orderBy(asc(runEvents.sequence)),
  ]);
  return { run, attempts, events };
}

export async function listRunSnapshots(userId: string): Promise<ReadonlyArray<RunSnapshot>> {
  const rows = await cloudDb().select().from(runs).where(eq(runs.userId, userId)).orderBy(desc(runs.createdAt)).limit(50);
  return Promise.all(rows.map(async (run) => {
    const [attempts, events] = await Promise.all([
      cloudDb().select().from(runAttempts).where(eq(runAttempts.runId, run.id)).orderBy(asc(runAttempts.ordinal)),
      cloudDb().select().from(runEvents).where(eq(runEvents.runId, run.id)).orderBy(asc(runEvents.sequence)),
    ]);
    return { run, attempts, events };
  }));
}

export async function markAttemptRunning(runId: string, attemptId: string): Promise<void> {
  const db = cloudDb();
  await db.update(runs).set({ status: "running", updatedAt: new Date() }).where(eq(runs.id, runId));
  await db.update(runAttempts).set({ status: "running", startedAt: new Date(), updatedAt: new Date() }).where(and(eq(runAttempts.id, attemptId), eq(runAttempts.runId, runId)));
  await appendRunEvent(runId, attemptId, "attempt.started", {});
}

export async function markAttemptSucceeded(input: {
  readonly runId: string;
  readonly attemptId: string;
  readonly providerVmId: string;
  readonly result: Record<string, unknown>;
}): Promise<void> {
  const now = new Date();
  const db = cloudDb();
  await db.update(runAttempts).set({ status: "succeeded", providerVmId: input.providerVmId, result: input.result, finishedAt: now, updatedAt: now }).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId)));
  await appendRunEvent(input.runId, input.attemptId, "attempt.succeeded", { providerVmId: input.providerVmId });
  await db.update(runs).set({ status: "succeeded", completedAt: now, updatedAt: now }).where(eq(runs.id, input.runId));
}

export async function markAttemptFailed(input: { readonly runId: string; readonly attemptId: string; readonly error: string }): Promise<void> {
  const now = new Date();
  const db = cloudDb();
  await db.update(runAttempts).set({ status: "failed", error: input.error.slice(0, 1_000), finishedAt: now, updatedAt: now }).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId)));
  await appendRunEvent(input.runId, input.attemptId, "attempt.failed", { error: input.error.slice(0, 1_000) });
  await db.update(runs).set({ status: "failed", error: input.error.slice(0, 1_000), completedAt: now, updatedAt: now }).where(eq(runs.id, input.runId));
}

async function appendRunEvent(runId: string, attemptId: string, kind: "attempt.started" | "attempt.succeeded" | "attempt.failed", payload: Record<string, unknown>): Promise<void> {
  const db = cloudDb();
  const latest = await db.select({ sequence: runEvents.sequence }).from(runEvents).where(eq(runEvents.runId, runId)).orderBy(desc(runEvents.sequence)).limit(1);
  await db.insert(runEvents).values({ runId, attemptId, sequence: (latest[0]?.sequence ?? -1) + 1, kind, payload });
}
