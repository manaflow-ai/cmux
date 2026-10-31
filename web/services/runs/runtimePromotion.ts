import { randomUUID } from "node:crypto";
import { and, eq, notExists, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudRuntimeWorkspaces, cloudRuntimes, runAttempts } from "../../db/schema";
import { createRuntime, getRuntime, promoteAttemptToRuntime } from "../vms/runtimeRepository";
import type { AttemptPromotionRuntimePort, PromotionRuntimeInput, PromotionRuntimeResult } from "./promotion";

/**
 * Promote an already-running fan-out terminal into a durable Runtime/workspace.
 * The provider handles are copied into the private workspace row; they never
 * cross the promotion view. Replays use the same request key and preserve the
 * terminal-derived session identity.
 */
export function createRuntimePromotionAdapter(): AttemptPromotionRuntimePort {
  return {
    async promote(input: PromotionRuntimeInput): Promise<PromotionRuntimeResult> {
      const ownerTeamId = input.billingTeamId?.trim() || input.userId;
      const runtime = await createRuntime({
        ownerTeamId,
        kind: "persistent",
        lifecycleState: "running",
        journalSessionId: input.sessionId,
        idempotencyKey: `run-promotion:${input.requestKey}`,
      });
      try {
        return await finishPromotion(input, ownerTeamId, runtime.id);
      } catch (error) {
        await releaseUnattachedRuntime(ownerTeamId, runtime.id).catch((releaseError: unknown) => {
          console.error("[runs] failed to release a refused promotion's runtime", { runtimeId: runtime.id }, releaseError);
        });
        throw error;
      }
    },
  };
}

async function finishPromotion(input: PromotionRuntimeInput, ownerTeamId: string, runtimeId: string): Promise<PromotionRuntimeResult> {
  const existing = await cloudDb().select().from(cloudRuntimeWorkspaces)
    .where(eq(cloudRuntimeWorkspaces.runtimeId, runtimeId)).limit(1);
  if (!existing[0]) {
    await cloudDb().insert(cloudRuntimeWorkspaces).values({
      runtimeId,
      ownerTeamId,
      workspaceId: `workspace_${randomUUID()}`,
      workspaceName: `Promoted ${input.runId.slice(0, 8)}`,
      provider: "freestyle",
      lifecycle: "running",
      providerVmId: input.providerVmId,
      providerWorkspaceId: input.providerWorkspaceId,
      providerTerminalId: input.providerTerminalId,
      ownerId: input.userId,
      idempotencyKey: `run-promotion:${input.requestKey}`,
      requestDigest: `promotion:${input.runId}:${input.attemptId}`,
      version: 1,
    }).onConflictDoNothing();
  }
  const workspace = (await cloudDb().select().from(cloudRuntimeWorkspaces)
    .where(eq(cloudRuntimeWorkspaces.runtimeId, runtimeId)).limit(1))[0];
  if (!workspace) throw new Error("promoted runtime workspace was not persisted");
  await promoteAttemptToRuntime({
    ownerTeamId,
    runId: input.runId,
    attemptId: input.attemptId,
    runtimeId,
  });
  const current = await getRuntime({ ownerTeamId, runtimeId });
  return {
    runtimeId,
    workspaceId: workspace.workspaceId,
    state: current?.lifecycleState === "suspended" ? "paused" : "ready",
    sessionId: input.sessionId,
    transport: "cmux-remote",
  };
}

/**
 * A refused promotion (the attempt changed, or the retention reaper holds it) has already
 * created its runtime. Left running, that runtime keeps the terminal's journal session id,
 * which is unique, so every later promotion of the attempt would hit a placement conflict.
 * Release it and free its idempotency keys, unless an attempt has attached to it. The
 * attempt's VM is not touched: it still belongs to the attempt.
 */
async function releaseUnattachedRuntime(ownerTeamId: string, runtimeId: string): Promise<void> {
  await cloudDb().transaction(async (tx) => {
    const releasedAt = new Date();
    const [released] = await tx.update(cloudRuntimes).set({
      lifecycleState: "released",
      releasedAt,
      updatedAt: releasedAt,
      journalSessionId: null,
      idempotencyKey: null,
      placementGeneration: sql`${cloudRuntimes.placementGeneration} + 1`,
    }).where(and(
      eq(cloudRuntimes.id, runtimeId),
      eq(cloudRuntimes.ownerTeamId, ownerTeamId),
      notExists(tx.select({ id: runAttempts.id }).from(runAttempts).where(eq(runAttempts.runtimeId, runtimeId))),
    )).returning({ id: cloudRuntimes.id });
    if (!released) return;
    await tx.update(cloudRuntimeWorkspaces).set({
      lifecycle: "failed",
      failureCode: "promotion_refused",
      failureMessage: "The run attempt could not be promoted; the runtime was released.",
      providerVmId: null,
      providerWorkspaceId: null,
      providerTerminalId: null,
      idempotencyKey: `run-promotion-released:${runtimeId}`,
      version: sql`${cloudRuntimeWorkspaces.version} + 1`,
      updatedAt: releasedAt,
    }).where(eq(cloudRuntimeWorkspaces.runtimeId, runtimeId));
  });
}
