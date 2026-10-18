import { and, eq, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudRuntimeWorkspaces, cloudRuntimes, hugeBlueAttachTokens } from "../../db/schema";
import { createRuntime, getRuntime, updateRuntime } from "./runtimeRepository";
import type { PersistentWorkspaceRecord, PersistentWorkspaceStore } from "./persistentWorkspace";

function lifecycleState(value: string): PersistentWorkspaceRecord["lifecycle"] {
  if (value === "provisioning" || value === "running" || value === "suspended" || value === "stopped" || value === "failed") {
    return value;
  }
  throw new Error(`invalid persistent workspace lifecycle: ${value}`);
}

function toRecord(row: typeof cloudRuntimeWorkspaces.$inferSelect): PersistentWorkspaceRecord {
  return {
    runtimeId: row.runtimeId,
    workspaceId: row.workspaceId,
    tenantId: row.ownerTeamId,
    ownerId: row.ownerId,
    provider: row.provider as PersistentWorkspaceRecord["provider"],
    lifecycle: lifecycleState(row.lifecycle),
    providerVmId: row.providerVmId,
    providerWorkspaceId: row.providerWorkspaceId,
    providerTerminalId: row.providerTerminalId,
    idempotencyKey: row.idempotencyKey,
    requestDigest: row.requestDigest,
    workspaceName: row.workspaceName,
    failureCode: row.failureCode,
    failureMessage: row.failureMessage,
    version: row.version,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

export function persistentWorkspaceStoreFromRuntime(): PersistentWorkspaceStore {
  return {
    async createRuntime({ record }) {
      const existing = await cloudDb().select().from(cloudRuntimeWorkspaces).where(and(
        eq(cloudRuntimeWorkspaces.ownerTeamId, record.tenantId),
        eq(cloudRuntimeWorkspaces.idempotencyKey, record.idempotencyKey),
      )).limit(1);
      if (existing[0]) return { record: toRecord(existing[0]), created: false };

      const runtime = await createRuntime({
        ownerTeamId: record.tenantId,
        kind: "persistent",
        lifecycleState: lifecycleState(record.lifecycle),
        idempotencyKey: record.idempotencyKey,
      });
      const inserted = await cloudDb().insert(cloudRuntimeWorkspaces).values({
        runtimeId: runtime.id,
        ownerTeamId: record.tenantId,
        workspaceId: record.workspaceId,
        workspaceName: record.workspaceName,
        lifecycle: record.lifecycle,
        ownerId: record.ownerId,
        provider: record.provider,
        idempotencyKey: record.idempotencyKey,
        requestDigest: record.requestDigest,
        version: 1,
      }).returning();
      return { record: toRecord(inserted[0]), created: true };
    },

    async getRuntime({ runtimeId }) {
      const [row] = await cloudDb().select({ workspace: cloudRuntimeWorkspaces, runtime: cloudRuntimes })
        .from(cloudRuntimeWorkspaces)
        .innerJoin(cloudRuntimes, eq(cloudRuntimes.id, cloudRuntimeWorkspaces.runtimeId))
        .where(eq(cloudRuntimeWorkspaces.runtimeId, runtimeId))
        .limit(1);
      return row ? toRecord(row.workspace) : null;
    },

    async updateRuntime({ runtimeId, patch, expectedVersion }) {
      return cloudDb().transaction(async (tx) => {
        const [current] = await tx.select().from(cloudRuntimeWorkspaces)
          .where(and(eq(cloudRuntimeWorkspaces.runtimeId, runtimeId), ...(expectedVersion === undefined ? [] : [eq(cloudRuntimeWorkspaces.version, expectedVersion)])))
          .for("update").limit(1);
        if (!current) throw new Error("workspace version is stale or missing");
        if (patch.lifecycle && patch.lifecycle !== "running") {
          await tx.update(hugeBlueAttachTokens).set({ revokedAt: new Date() }).where(eq(hugeBlueAttachTokens.runtimeId, runtimeId));
        }
        const nextLifecycle = patch.lifecycle ? lifecycleState(patch.lifecycle) : lifecycleState(current.lifecycle);
        const [updated] = await tx.update(cloudRuntimeWorkspaces).set({
          ...patch,
          lifecycle: nextLifecycle,
          version: sql`${cloudRuntimeWorkspaces.version} + 1`,
          updatedAt: new Date(),
        }).where(eq(cloudRuntimeWorkspaces.runtimeId, runtimeId)).returning();
        const runtime = await getRuntime({ ownerTeamId: current.ownerTeamId, runtimeId });
        if (runtime) {
          await updateRuntime({
            ownerTeamId: current.ownerTeamId,
            runtimeId,
            lifecycleState: nextLifecycle,
            expectedPlacementGeneration: runtime.placementGeneration,
          });
        }
        return toRecord(updated);
      });
    },
  };
}
