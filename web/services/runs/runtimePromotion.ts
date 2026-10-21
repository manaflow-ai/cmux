import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudRuntimeWorkspaces } from "../../db/schema";
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
      const existing = await cloudDb().select().from(cloudRuntimeWorkspaces)
        .where(eq(cloudRuntimeWorkspaces.runtimeId, runtime.id)).limit(1);
      if (!existing[0]) {
        await cloudDb().insert(cloudRuntimeWorkspaces).values({
          runtimeId: runtime.id,
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
        .where(eq(cloudRuntimeWorkspaces.runtimeId, runtime.id)).limit(1))[0];
      if (!workspace) throw new Error("promoted runtime workspace was not persisted");
      await promoteAttemptToRuntime({
        ownerTeamId,
        runId: input.runId,
        attemptId: input.attemptId,
        runtimeId: runtime.id,
      });
      const current = await getRuntime({ ownerTeamId, runtimeId: runtime.id });
      return {
        runtimeId: runtime.id,
        workspaceId: workspace.workspaceId,
        state: current?.lifecycleState === "suspended" ? "paused" : "ready",
        sessionId: input.sessionId,
        transport: "cmux-remote",
      };
    },
  };
}
