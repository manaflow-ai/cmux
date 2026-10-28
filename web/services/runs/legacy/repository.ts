import { createHash } from "node:crypto";
import { and, asc, desc, eq, isNull, or, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { runArtifacts, runAttempts, runEvents, runs } from "../../../db/schema";
import type { RunSpec } from "./spec";

export type RunScope = { readonly userId: string; readonly ownerTeamId: string };
export type RunSnapshot = {
  readonly run: typeof runs.$inferSelect;
  readonly attempts: ReadonlyArray<typeof runAttempts.$inferSelect>;
  readonly events: ReadonlyArray<typeof runEvents.$inferSelect>;
  readonly artifacts: ReadonlyArray<typeof runArtifacts.$inferSelect>;
};
export class RunIdempotencyConflictError extends Error {}
export class RunAdmissionError extends Error {}
export class RunArtifactConflictError extends Error {}
type RunReadDatabase = Pick<ReturnType<typeof cloudDb>, "select">;
type RunAdmissionDatabase = RunReadDatabase & Pick<ReturnType<typeof cloudDb>, "transaction">;

function scopeWhere(scope: RunScope) {
  return or(eq(runs.ownerTeamId, scope.ownerTeamId), and(isNull(runs.ownerTeamId), eq(runs.userId, scope.userId)));
}

export async function createRunRecord(input: RunScope & {
  readonly billingTeamId: string | null;
  readonly idempotencyKey: string;
  readonly requestDigest: string;
  readonly spec: RunSpec;
}, database: RunAdmissionDatabase = cloudDb()): Promise<{ readonly snapshot: RunSnapshot; readonly reused: boolean }> {
  const result = await database.transaction(async (tx) => {
    // One admission lock per immutable owner serializes duplicate keys AND the
    // bounded queue count. Provider capacity remains owned by createVm.
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run-admission:${input.ownerTeamId}`}, 0))`);
    const [existing] = await tx.select().from(runs).where(and(eq(runs.ownerTeamId, input.ownerTeamId), eq(runs.idempotencyKey, input.idempotencyKey))).limit(1);
    if (existing) {
      if (existing.requestDigest !== input.requestDigest) throw new RunIdempotencyConflictError("Idempotency-Key conflicts with the original RunSpec");
      return { id: existing.id, reused: true };
    }
    const [{ count }] = await tx.select({ count: sql<number>`count(*)::int` }).from(runs).where(and(eq(runs.ownerTeamId, input.ownerTeamId), sql`${runs.status} in ('queued', 'running')`));
    if (count >= 16) throw new RunAdmissionError("This team already has 16 queued or running Runs");
    const [run] = await tx.insert(runs).values({
      userId: input.userId, ownerTeamId: input.ownerTeamId, billingTeamId: input.billingTeamId,
      idempotencyKey: input.idempotencyKey, requestDigest: input.requestDigest,
      source: input.spec.source, spec: input.spec as unknown as Record<string, unknown>,
      recipe: input.spec.recipe.id, provider: "cloud-vm", desiredAttempts: input.spec.variants.length, status: "queued",
    }).returning();
    const attempts = await tx.insert(runAttempts).values(input.spec.variants.map((variant, ordinal) => ({ runId: run.id, ordinal, variant, status: "queued" as const }))).returning();
    await tx.insert(runEvents).values([
      { runId: run.id, sequence: 0, kind: "run.created" as const, payload: { requestDigest: input.requestDigest, desiredAttempts: attempts.length } },
      ...attempts.map((attempt, index) => ({ runId: run.id, attemptId: attempt.id, sequence: index + 1, kind: "attempt.queued" as const, payload: { ordinal: attempt.ordinal, variantId: input.spec.variants[attempt.ordinal].id } })),
    ]);
    return { id: run.id, reused: false };
  });
  const snapshot = await readRunSnapshot(result.id, input, database);
  if (!snapshot) throw new Error("Run record disappeared after admission");
  return { snapshot, reused: result.reused };
}

export async function readRunSnapshot(runId: string, scope: RunScope, database: RunReadDatabase = cloudDb()): Promise<RunSnapshot | null> {
  const [run] = await database.select().from(runs).where(and(eq(runs.id, runId), scopeWhere(scope))).limit(1);
  if (!run) return null;
  const [attempts, events, artifacts] = await Promise.all([
    database.select().from(runAttempts).where(eq(runAttempts.runId, run.id)).orderBy(asc(runAttempts.ordinal)),
    database.select().from(runEvents).where(eq(runEvents.runId, run.id)).orderBy(asc(runEvents.sequence)).limit(1000),
    database.select().from(runArtifacts).where(eq(runArtifacts.runId, run.id)).orderBy(asc(runArtifacts.createdAt)).limit(128),
  ]);
  return { run, attempts, events, artifacts };
}

export async function listRunSnapshots(scope: RunScope): Promise<ReadonlyArray<RunSnapshot>> {
  const rows = await cloudDb().select({ id: runs.id }).from(runs).where(scopeWhere(scope)).orderBy(desc(runs.createdAt)).limit(50);
  const snapshots = await Promise.all(rows.map(({ id }) => readRunSnapshot(id, scope)));
  return snapshots.filter((snapshot): snapshot is RunSnapshot => snapshot !== null);
}

/** Receipt payloads are content addressed and immutable across worker replay. */
export async function storeRunArtifact(input: { runId: string; attemptId: string; name: string; payload: Record<string, unknown> }): Promise<void> {
  const bytes = JSON.stringify(input.payload);
  const digest = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
  await cloudDb().transaction(async (tx) => {
    const [attempt] = await tx.select({ runId: runAttempts.runId }).from(runAttempts).where(eq(runAttempts.id, input.attemptId)).limit(1);
    if (!attempt || attempt.runId !== input.runId) throw new RunArtifactConflictError("Run artifact does not belong to this attempt");
    const [existing] = await tx.select({ digest: runArtifacts.digest }).from(runArtifacts).where(and(eq(runArtifacts.attemptId, input.attemptId), eq(runArtifacts.name, input.name))).limit(1);
    if (existing) {
      if (existing.digest !== digest) throw new RunArtifactConflictError("Run artifact content is immutable");
      return;
    }
    await tx.insert(runArtifacts).values({ ...input, digest, sizeBytes: Buffer.byteLength(bytes) });
  });
}
