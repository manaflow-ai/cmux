import { and, asc, eq, inArray, isNull, or, sql } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { cloudDb } from "../../db/client";
import { cloudRuntimeAgentBindings, cloudRuntimes, cloudVms } from "../../db/schema";
import { VmDatabaseError } from "./errors";

export type CloudRuntimeRow = typeof cloudRuntimes.$inferSelect;
export type HiveRuntimeAgentBinding = typeof cloudRuntimeAgentBindings.$inferSelect;

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

export type HiveRuntimePlacementState = "running" | "paused" | "provisioning" | "unplaced";

export type HiveRuntimePlacementResolution = HiveRuntimeRecord & {
  readonly state: HiveRuntimePlacementState;
  readonly providerVmId: string | null;
};

export type HiveRuntimeLivePlacement = HiveRuntimePlacementResolution & {
  readonly state: "running" | "paused";
  readonly providerVmId: string;
};

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

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
  return isUuid(expected.runtimeId) && isUuid(expected.machineId) &&
    Number.isSafeInteger(expected.generation) && expected.generation > 0 &&
    runtime.id === expected.runtimeId && runtime.machineId === expected.machineId &&
    runtime.placementGeneration === expected.generation;
}

export function hiveRuntimePlacementState(
  machine: typeof cloudVms.$inferSelect | null,
): HiveRuntimePlacementState {
  if (!machine) return "unplaced";
  if (machine.status === "running") return "running";
  if (machine.status === "paused") return "paused";
  if (machine.status === "provisioning") return "provisioning";
  return "unplaced";
}

function placementResolution(
  record: HiveRuntimeRecord,
): HiveRuntimePlacementResolution {
  const state = hiveRuntimePlacementState(record.machine);
  return {
    ...record,
    state,
    providerVmId: state === "running" || state === "paused"
      ? record.machine?.providerVmId ?? null
      : null,
  };
}

type HiveRuntimePlacementLookup = {
  readonly ownerTeamId: string;
  readonly runtimeId: string;
  readonly expected?: HiveRuntimePlacement;
};

function resolveHiveRuntimeByWhere(
  input: HiveRuntimePlacementLookup,
  where: ReturnType<typeof and>,
  operation: string,
) {
  return Effect.tryPromise({
    try: async (): Promise<HiveRuntimePlacementResolution | null> => {
      const [record] = await cloudDb().select({ runtime: cloudRuntimes, machine: cloudVms })
        .from(cloudRuntimes)
        .leftJoin(cloudVms, and(
          eq(cloudVms.id, cloudRuntimes.machineId),
          eq(cloudVms.ownerTeamId, cloudRuntimes.ownerTeamId),
        ))
        .where(where)
        .limit(1);
      if (!record) return null;
      const expected = input.expected;
      if (expected && !isCurrentHiveRuntimePlacement(record.runtime, expected)) return null;
      return placementResolution(record);
    },
    catch: (cause) => new VmDatabaseError({ operation, cause }),
  });
}

/**
 * Resolves a durable runtime to its current machine placement. The expected
 * tuple is an optional stale fence for callers that carried a placement across
 * an asynchronous wake or provider operation. This resolver never wakes a VM.
 */
export function resolveHiveRuntimePlacement(input: {
  readonly ownerTeamId: string;
  readonly runtimeId: string;
  readonly expected?: HiveRuntimePlacement;
}) {
  return resolveHiveRuntimeByWhere(
    input,
    and(eq(cloudRuntimes.id, input.runtimeId), eq(cloudRuntimes.ownerTeamId, input.ownerTeamId)),
    "resolveHiveRuntimePlacement",
  );
}

/** Resolves only a placement that can accept live provider operations. */
export function resolveHiveRuntimeLivePlacement(input: {
  readonly ownerTeamId: string;
  readonly runtimeId: string;
  readonly expected?: HiveRuntimePlacement;
}) {
  return resolveHiveRuntimePlacement(input).pipe(
    Effect.map((resolution): HiveRuntimeLivePlacement | null => {
      if (!resolution ||
          (resolution.state !== "running" && resolution.state !== "paused") ||
          !resolution.providerVmId) return null;
      return resolution as HiveRuntimeLivePlacement;
    }),
  );
}

/** Resolves the runtime owning an internal cloud machine row. */
export function resolveHiveRuntimeByMachineId(input: {
  readonly ownerTeamId: string;
  readonly machineId: string;
  readonly expected?: HiveRuntimePlacement;
}) {
  return resolveHiveRuntimeByWhere(
    { ...input, runtimeId: input.expected?.runtimeId ?? "" },
    and(eq(cloudRuntimes.ownerTeamId, input.ownerTeamId), eq(cloudRuntimes.machineId, input.machineId)),
    "resolveHiveRuntimeByMachineId",
  );
}

/** Resolves a runtime from the provider VM id used by legacy Cloud routes. */
export function resolveHiveRuntimeByProviderVmId(input: {
  readonly ownerTeamId: string;
  readonly provider: typeof cloudVms.$inferSelect["provider"];
  readonly providerVmId: string;
  readonly expected?: HiveRuntimePlacement;
}) {
  return resolveHiveRuntimeByWhere(
    { ...input, runtimeId: input.expected?.runtimeId ?? "" },
    and(
      eq(cloudRuntimes.ownerTeamId, input.ownerTeamId),
      eq(cloudVms.provider, input.provider),
      eq(cloudVms.providerVmId, input.providerVmId),
      eq(cloudVms.ownerTeamId, input.ownerTeamId),
    ),
    "resolveHiveRuntimeByProviderVmId",
  );
}

function normalizedBindingText(value: string | null | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
}

/**
 * Lists Codex root/child identity bindings for an account-visible runtime.
 * These are identity links only; Codex remains authoritative for transcripts
 * and resume references, while cmux owns the runtime journal and resources.
 */
export function listHiveRuntimeAgentBindings(ownerTeamId: string, runtimeId: string, limit = 100) {
  return Effect.tryPromise({
    try: async (): Promise<readonly HiveRuntimeAgentBinding[]> => {
      const boundedLimit = Number.isSafeInteger(limit) ? Math.max(1, Math.min(limit, 100)) : 100;
      return await cloudDb().select({ binding: cloudRuntimeAgentBindings })
        .from(cloudRuntimeAgentBindings)
        .innerJoin(cloudRuntimes, eq(cloudRuntimes.id, cloudRuntimeAgentBindings.runtimeId))
        .where(and(
          eq(cloudRuntimes.ownerTeamId, ownerTeamId),
          eq(cloudRuntimeAgentBindings.runtimeId, runtimeId),
        ))
        .orderBy(asc(cloudRuntimeAgentBindings.codexThreadId))
        .limit(boundedLimit)
        .then((rows) => rows.map(({ binding }) => binding));
    },
    catch: (cause) => new VmDatabaseError({ operation: "listHiveRuntimeAgentBindings", cause }),
  });
}

/**
 * Adds one immutable Codex identity link to a runtime. Repeating the exact
 * binding is idempotent; attempting to reuse a thread ID with another root or
 * parent returns null. No placement or machine lookup is required.
 */
export function bindHiveRuntimeAgent(input: {
  readonly ownerTeamId: string;
  readonly runtimeId: string;
  readonly codexThreadId: string;
  readonly rootChatId: string;
  readonly parentChatId?: string | null;
}) {
  return Effect.tryPromise({
    try: async (): Promise<HiveRuntimeAgentBinding | null> => {
      const codexThreadId = normalizedBindingText(input.codexThreadId);
      const rootChatId = normalizedBindingText(input.rootChatId);
      const parentChatId = normalizedBindingText(input.parentChatId);
      if (!codexThreadId || !rootChatId) return null;
      const [runtime] = await cloudDb().select({ id: cloudRuntimes.id })
        .from(cloudRuntimes)
        .where(and(eq(cloudRuntimes.id, input.runtimeId), eq(cloudRuntimes.ownerTeamId, input.ownerTeamId)))
        .limit(1);
      if (!runtime) return null;
      const [inserted] = await cloudDb().insert(cloudRuntimeAgentBindings).values({
        runtimeId: input.runtimeId,
        codexThreadId,
        rootChatId,
        parentChatId,
      }).onConflictDoNothing().returning();
      if (inserted) return inserted;
      const [existing] = await cloudDb().select()
        .from(cloudRuntimeAgentBindings)
        .where(and(
          eq(cloudRuntimeAgentBindings.runtimeId, input.runtimeId),
          eq(cloudRuntimeAgentBindings.codexThreadId, codexThreadId),
        ))
        .limit(1);
      return existing && existing.rootChatId === rootChatId && existing.parentChatId === parentChatId
        ? existing
        : null;
    },
    catch: (cause) => new VmDatabaseError({ operation: "bindHiveRuntimeAgent", cause }),
  });
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
      try {
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
      } catch (cause) {
        if (postgresErrorCode(cause) === "23505") return false;
        throw cause;
      }
    },
    catch: (cause) => new VmDatabaseError({ operation: "bindHiveRuntimeJournal", cause }),
  });
}
