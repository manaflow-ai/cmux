import { and, eq, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { cloudRuntimes, cloudVms, runAttempts } from "../../../db/schema";
import { RunHttpError, runNotFound } from "./http";
import { readRunSnapshot, type RunScope } from "./repository";

/** Promotion transfers retention ownership to the existing Cloud machine
 * lifecycle. It does not fork compute or invent a new runtime identity. */
export async function promoteRunAttempt(input: RunScope & { runId: string; attemptId: string }) {
  const snapshot = await readRunSnapshot(input.runId, input);
  if (!snapshot) runNotFound();
  return cloudDb().transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`run:${input.runId}`}, 0))`);
    const [attempt] = await tx.select().from(runAttempts).where(and(eq(runAttempts.runId, input.runId), eq(runAttempts.id, input.attemptId))).for("update");
    if (!attempt || !attempt.providerVmId) runNotFound();
    if (attempt.status !== "succeeded" || attempt.cleanupState !== "retained") throw new RunHttpError(409, "run_promotion_unavailable", "Only a retained successful attempt can become a dev box");
    if (!attempt.promotedAt && (!attempt.retainedUntil || attempt.retainedUntil.getTime() <= Date.now())) throw new RunHttpError(409, "run_retention_expired", "Attempt retention has expired");
    const [runtime] = await tx.select({ id: cloudRuntimes.id, sessionId: cloudRuntimes.journalSessionId }).from(cloudRuntimes).innerJoin(cloudVms, eq(cloudVms.id, cloudRuntimes.machineId)).where(and(eq(cloudVms.providerVmId, attempt.providerVmId), eq(cloudRuntimes.ownerTeamId, input.ownerTeamId), eq(cloudVms.ownerTeamId, input.ownerTeamId), eq(cloudVms.status, "running"))).limit(1);
    if (!runtime) throw new RunHttpError(409, "run_runtime_unavailable", "The attempt's Cloud runtime is not running");
    await tx.update(runAttempts).set({ promotedAt: attempt.promotedAt ?? new Date(), runtimeId: runtime.id, retainedUntil: null, updatedAt: new Date() }).where(eq(runAttempts.id, attempt.id));
    return { id: runtime.id, runId: input.runId, attemptId: input.attemptId, runtime: { id: runtime.id, state: "running", sessionId: runtime.sessionId }, workspace: { id: runtime.id, kind: "persistent", state: "running", sessionId: runtime.sessionId }, createdAt: attempt.promotedAt ?? new Date() };
  });
}
