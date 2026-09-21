import { and, eq, inArray, isNull, or, sql } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { cloudDb } from "../../db/client";
import { cloudRuntimes, cloudVms } from "../../db/schema";
import { VmDatabaseError } from "./errors";

export type CloudRuntimeRow = typeof cloudRuntimes.$inferSelect;

/** Exact incarnation carried across asynchronous work; never a journal cursor. */
export type HiveRuntimePlacement = {
  readonly runtimeId: string;
  readonly machineId: string;
  readonly generation: number;
};

/** A live VM is read through its existing owner, never duplicated into the registry. */
export type HiveRuntimeRecord = {
  readonly runtime: CloudRuntimeRow;
  readonly machine: typeof cloudVms.$inferSelect | null;
};

function postgresErrorCode(cause: unknown): string | null {
  if (!cause || typeof cause !== "object") return null;
  const code = (cause as { code?: unknown }).code;
  if (typeof code === "string") return code;
  return postgresErrorCode((cause as { cause?: unknown }).cause);
}

/** Compares the complete placement, so another runtime's generation 1 is stale too. */
export function isCurrentHiveRuntimePlacement(
  runtime: CloudRuntimeRow,
  expected: HiveRuntimePlacement,
): boolean {
  return Number.isSafeInteger(expected.generation) && expected.generation > 0 &&
    runtime.id === expected.runtimeId && runtime.machineId === expected.machineId &&
    runtime.placementGeneration === expected.generation;
}

/** Reads account-visible identity even when its compute row has disappeared. */
export function readHiveRuntime(ownerTeamId: string, runtimeId: string) {
  return Effect.tryPromise({
    try: async (): Promise<HiveRuntimeRecord | null> => {
      const [record] = await cloudDb().select({ runtime: cloudRuntimes, machine: cloudVms })
        .from(cloudRuntimes)
        .leftJoin(cloudVms, and(
          eq(cloudVms.id, cloudRuntimes.machineId),
          eq(cloudVms.ownerTeamId, cloudRuntimes.ownerTeamId),
          inArray(cloudVms.status, ["provisioning", "running", "paused"]),
        ))
        .where(and(eq(cloudRuntimes.id, runtimeId), eq(cloudRuntimes.ownerTeamId, ownerTeamId)))
        .limit(1);
      return record ?? null;
    },
    catch: (cause) => new VmDatabaseError({ operation: "readHiveRuntime", cause }),
  });
}

/**
 * Binds an observed lineage once, under the complete current placement fence.
 * Returns false for a stale placement, inaccessible runtime, or different lineage.
 * This is persistence preparation; no guest or request route invokes it in M0-A.
 */
export function bindHiveRuntimeJournal(input: {
  readonly ownerTeamId: string;
  readonly placement: HiveRuntimePlacement;
  readonly journalSessionId: string;
}) {
  return Effect.tryPromise({
    try: async () => {
      if (!/^session_[0-9a-f]{32}$/.test(input.journalSessionId) ||
          !Number.isSafeInteger(input.placement.generation) || input.placement.generation < 1) {
        return false;
      }
      const rows = await cloudDb().update(cloudRuntimes)
        .set({ journalSessionId: input.journalSessionId })
        .where(and(
          eq(cloudRuntimes.id, input.placement.runtimeId),
          eq(cloudRuntimes.ownerTeamId, input.ownerTeamId),
          eq(cloudRuntimes.machineId, input.placement.machineId),
          eq(cloudRuntimes.placementGeneration, input.placement.generation),
          or(isNull(cloudRuntimes.journalSessionId), eq(cloudRuntimes.journalSessionId, input.journalSessionId)),
          sql`exists (select 1 from ${cloudVms} where ${cloudVms.id} = ${cloudRuntimes.machineId}
            and ${cloudVms.ownerTeamId} = ${cloudRuntimes.ownerTeamId}
            and ${cloudVms.status} = 'running')`,
        )).returning({ id: cloudRuntimes.id });
      return rows.length === 1;
    },
    catch: (cause) => postgresErrorCode(cause) === "23505"
      ? false
      : new VmDatabaseError({ operation: "bindHiveRuntimeJournal", cause }),
  });
}
