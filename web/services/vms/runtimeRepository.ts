import { randomUUID } from "node:crypto";
import { and, eq, isNull, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudRuntimes, runAttempts, runs } from "../../db/schema";
import type {
  CreateRuntimeInput,
  RuntimeRow,
  UpdateRuntimeInput,
} from "./runtimeModel";

export {
  toRuntimeView,
  type CreateRuntimeInput,
  type RuntimeKind,
  type RuntimeLeaseFence,
  type RuntimeLifecycleState,
  type RuntimePlacement,
  type RuntimeRow,
  type RuntimeView,
  type UpdateRuntimeInput,
} from "./runtimeModel";

export class RuntimeNotFoundError extends Error {}
export class RuntimeIdempotencyConflictError extends Error {}
export class RuntimePlacementConflictError extends Error {}
export class RuntimeLeaseConflictError extends Error {}
export class RuntimeUnavailableError extends Error {}
export class RuntimeAttemptNotFoundError extends Error {}
export class RuntimeAttemptConflictError extends Error {}

function now(): Date {
  return new Date();
}

function owner(value: string): string {
  const normalized = value.trim();
  if (!normalized) throw new Error("ownerTeamId is required");
  return normalized;
}

function optionalText(value: string | null | undefined): string | null | undefined {
  if (value === undefined || value === null) return value;
  const normalized = value.trim();
  return normalized || null;
}

function idempotency(value: string | null | undefined): string | null {
  const normalized = optionalText(value);
  if (!normalized) return null;
  if (normalized.length > 128) throw new Error("idempotencyKey must be at most 128 characters");
  return normalized;
}

function runOwnerTeamId(run: { readonly userId: string; readonly billingTeamId: string | null }): string {
  return (run.billingTeamId?.trim() || run.userId.trim());
}

function sameCreateRequest(existing: RuntimeRow, input: {
  readonly kind: RuntimeRow["runtimeKind"];
  readonly lifecycleState: RuntimeRow["lifecycleState"];
  readonly machineId: string | null;
  readonly journalSessionId: string | null;
}): boolean {
  return existing.runtimeKind === input.kind
    && existing.lifecycleState === input.lifecycleState
    && existing.machineId === input.machineId
    && existing.journalSessionId === input.journalSessionId;
}

function updateSet(input: UpdateRuntimeInput): Record<string, unknown> {
  const set: Record<string, unknown> = { updatedAt: now() };
  if (input.lifecycleState !== undefined) {
    set.lifecycleState = input.lifecycleState;
    set.releasedAt = input.lifecycleState === "released" ? now() : null;
  }
  if (input.machineId !== undefined) {
    set.machineId = optionalText(input.machineId) ?? null;
    set.placementGeneration = sql`${cloudRuntimes.placementGeneration} + 1`;
  }
  if (input.journalSessionId !== undefined) set.journalSessionId = optionalText(input.journalSessionId) ?? null;
  if (input.leaseToken !== undefined) set.leaseToken = input.leaseToken;
  if (input.leaseExpiresAt !== undefined) set.leaseExpiresAt = input.leaseExpiresAt;
  if (input.leaseToken !== undefined && input.expectedLeaseGeneration !== undefined) {
    set.leaseGeneration = sql`${cloudRuntimes.leaseGeneration} + 1`;
  }
  return set;
}

function updateConditions(input: UpdateRuntimeInput, ownerTeamId: string) {
  const conditions = [
    eq(cloudRuntimes.id, input.runtimeId),
    eq(cloudRuntimes.ownerTeamId, ownerTeamId),
  ];
  if (input.expectedPlacementGeneration !== undefined) {
    conditions.push(eq(cloudRuntimes.placementGeneration, input.expectedPlacementGeneration));
  }
  if (input.expectedLeaseGeneration !== undefined) {
    conditions.push(eq(cloudRuntimes.leaseGeneration, input.expectedLeaseGeneration));
  }
  return conditions;
}

/** Create a tenant-owned runtime. Retries with the same key return the same row. */
export async function createRuntime(input: CreateRuntimeInput): Promise<RuntimeRow> {
  const ownerTeamId = owner(input.ownerTeamId);
  const runtimeKind = input.kind ?? "ephemeral";
  const lifecycleState = input.lifecycleState ?? "provisioning";
  const machineId = optionalText(input.machineId) ?? null;
  const journalSessionId = optionalText(input.journalSessionId) ?? null;
  const idempotencyKey = idempotency(input.idempotencyKey);

  return cloudDb().transaction(async (tx) => {
    if (idempotencyKey) {
      const [existing] = await tx.select().from(cloudRuntimes).where(and(
        eq(cloudRuntimes.ownerTeamId, ownerTeamId),
        eq(cloudRuntimes.idempotencyKey, idempotencyKey),
      )).limit(1);
      if (existing) {
        if (!sameCreateRequest(existing, { kind: runtimeKind, lifecycleState, machineId, journalSessionId })) {
          throw new RuntimeIdempotencyConflictError("runtime idempotency key was already used with a different request");
        }
        return existing;
      }
    }

    const inserted = (await tx.insert(cloudRuntimes).values({
      ownerTeamId,
      runtimeKind,
      lifecycleState,
      machineId,
      journalSessionId,
      idempotencyKey,
    }).onConflictDoNothing().returning())[0];
    if (inserted) return inserted;

    // A concurrent retry can win the partial idempotency index. Re-read it and
    // preserve idempotency; other conflicts (machine or journal) remain a
    // placement conflict rather than silently selecting another runtime.
    if (idempotencyKey) {
      const [existing] = await tx.select().from(cloudRuntimes).where(and(
        eq(cloudRuntimes.ownerTeamId, ownerTeamId),
        eq(cloudRuntimes.idempotencyKey, idempotencyKey),
      )).limit(1);
      if (existing) {
        if (!sameCreateRequest(existing, { kind: runtimeKind, lifecycleState, machineId, journalSessionId })) {
          throw new RuntimeIdempotencyConflictError("runtime idempotency key was already used with a different request");
        }
        return existing;
      }
    }
    throw new RuntimePlacementConflictError("runtime placement is already owned");
  });
}

/** Read a runtime only through its tenant owner. */
export async function getRuntime(input: { readonly ownerTeamId: string; readonly runtimeId: string }): Promise<RuntimeRow | null> {
  const [runtime] = await cloudDb().select().from(cloudRuntimes).where(and(
    eq(cloudRuntimes.id, input.runtimeId),
    eq(cloudRuntimes.ownerTeamId, owner(input.ownerTeamId)),
  )).limit(1);
  return runtime ?? null;
}

/**
 * Update lifecycle or placement state with optional placement and lease fences.
 * A placement mutation always increments placementGeneration atomically.
 */
export async function updateRuntime(input: UpdateRuntimeInput): Promise<RuntimeRow> {
  const ownerTeamId = owner(input.ownerTeamId);
  const placementMutation = input.machineId !== undefined || input.journalSessionId !== undefined;
  const leaseMutation = input.leaseToken !== undefined || input.leaseExpiresAt !== undefined;
  if (placementMutation && (!Number.isSafeInteger(input.expectedPlacementGeneration) || (input.expectedPlacementGeneration ?? 0) < 1)) {
    throw new RuntimePlacementConflictError("expectedPlacementGeneration is required for placement updates");
  }
  if (input.expectedLeaseGeneration !== undefined && (!Number.isSafeInteger(input.expectedLeaseGeneration) || input.expectedLeaseGeneration < 0)) {
    throw new RuntimeLeaseConflictError("expectedLeaseGeneration is invalid");
  }
  if (leaseMutation && input.expectedLeaseGeneration === undefined) {
    throw new RuntimeLeaseConflictError("expectedLeaseGeneration is required for lease updates");
  }

  // The placement and lease counters use SQL expressions (`column + 1`), so
  // this local update map intentionally permits both values and SQL wrappers.
  const set = updateSet(input);
  const conditions = updateConditions(input, ownerTeamId);

  const [updated] = await cloudDb().update(cloudRuntimes).set(set as never).where(and(...conditions)).returning();
  if (updated) return updated;
  const existing = await getRuntime({ ownerTeamId, runtimeId: input.runtimeId });
  if (!existing) throw new RuntimeNotFoundError("runtime not found");
  if (input.expectedPlacementGeneration !== undefined && existing.placementGeneration !== input.expectedPlacementGeneration) {
    throw new RuntimePlacementConflictError("runtime placement generation is stale");
  }
  throw new RuntimeLeaseConflictError("runtime lease generation is stale");
}

/**
 * Attach one run attempt to a runtime under the run's tenant owner. The
 * attempt/runtime pair is naturally idempotent; a second runtime is rejected
 * so a retry cannot silently move an in-flight attempt.
 */
export async function attachAttemptToRuntime(input: {
  readonly ownerTeamId: string;
  readonly runId: string;
  readonly attemptId: string;
  readonly runtimeId: string;
  readonly idempotencyKey?: string | null;
}): Promise<typeof runAttempts.$inferSelect> {
  const ownerTeamId = owner(input.ownerTeamId);
  return cloudDb().transaction(async (tx) => {
    const [runtime] = await tx.select().from(cloudRuntimes).where(and(
      eq(cloudRuntimes.id, input.runtimeId),
      eq(cloudRuntimes.ownerTeamId, ownerTeamId),
    )).for("update").limit(1);
    if (!runtime) throw new RuntimeNotFoundError("runtime not found");
    if (runtime.lifecycleState === "draining" || runtime.lifecycleState === "stopped" || runtime.lifecycleState === "released" || runtime.lifecycleState === "failed") {
      throw new RuntimeUnavailableError("runtime is not attachable");
    }

    const [run] = await tx.select({ userId: runs.userId, billingTeamId: runs.billingTeamId })
      .from(runs)
      .where(eq(runs.id, input.runId))
      .for("update")
      .limit(1);
    if (!run || runOwnerTeamId(run) !== ownerTeamId) throw new RuntimeNotFoundError("runtime not found");

    const [attempt] = await tx.select().from(runAttempts).where(and(
      eq(runAttempts.id, input.attemptId),
      eq(runAttempts.runId, input.runId),
    )).for("update").limit(1);
    if (!attempt) throw new RuntimeAttemptNotFoundError("run attempt not found");
    if (attempt.runtimeId && attempt.runtimeId !== input.runtimeId) {
      throw new RuntimeAttemptConflictError("run attempt is already attached to another runtime");
    }
    if (attempt.runtimeId === input.runtimeId) return attempt;

    const [attached] = await tx.update(runAttempts).set({
      runtimeId: input.runtimeId,
      updatedAt: now(),
    }).where(and(
      eq(runAttempts.id, input.attemptId),
      eq(runAttempts.runId, input.runId),
      isNull(runAttempts.runtimeId),
    )).returning();
    if (!attached) {
      throw new RuntimeAttemptConflictError("run attempt changed while attaching");
    }
    return attached;
  });
}

/**
 * Move a terminal fan-out attempt from its ephemeral execution Runtime into
 * the persistent Runtime created by promotion. The old Runtime remains
 * durable for cleanup/audit, while the attempt's current owner is atomically
 * switched under the same tenant and run locks.
 */
export async function promoteAttemptToRuntime(input: {
  readonly ownerTeamId: string;
  readonly runId: string;
  readonly attemptId: string;
  readonly runtimeId: string;
}): Promise<typeof runAttempts.$inferSelect> {
  const ownerTeamId = owner(input.ownerTeamId);
  return cloudDb().transaction(async (tx) => {
    const [runtime] = await tx.select().from(cloudRuntimes).where(and(
      eq(cloudRuntimes.id, input.runtimeId),
      eq(cloudRuntimes.ownerTeamId, ownerTeamId),
    )).for("update").limit(1);
    if (!runtime) throw new RuntimeNotFoundError("runtime not found");
    if (["draining", "stopped", "released", "failed"].includes(runtime.lifecycleState)) {
      throw new RuntimeUnavailableError("runtime is not attachable");
    }
    const [run] = await tx.select({ userId: runs.userId, billingTeamId: runs.billingTeamId })
      .from(runs).where(eq(runs.id, input.runId)).for("update").limit(1);
    if (!run || runOwnerTeamId(run) !== ownerTeamId) throw new RuntimeNotFoundError("runtime not found");
    const [attempt] = await tx.select().from(runAttempts).where(and(
      eq(runAttempts.id, input.attemptId),
      eq(runAttempts.runId, input.runId),
    )).for("update").limit(1);
    if (!attempt) throw new RuntimeAttemptNotFoundError("run attempt not found");
    if (!["succeeded", "failed", "cancelled"].includes(attempt.status)) {
      throw new RuntimeAttemptConflictError("only terminal attempts can be promoted");
    }
    if (attempt.runtimeId === input.runtimeId) return attempt;
    // The retention reaper has claimed this attempt and is destroying its VM (repository.ts
    // claimExpiredAttemptCleanups); a runtime promoted now would own a VM that is about to go.
    if (attempt.cleanupLeaseExpiresAt && attempt.cleanupLeaseExpiresAt > now()) {
      throw new RuntimeAttemptConflictError("run attempt's VM is being cleaned up");
    }
    const [moved] = await tx.update(runAttempts).set({
      runtimeId: input.runtimeId,
      updatedAt: now(),
    }).where(and(
      eq(runAttempts.id, input.attemptId),
      eq(runAttempts.runId, input.runId),
    )).returning();
    if (!moved) throw new RuntimeAttemptConflictError("run attempt changed while promoting");
    return moved;
  });
}

/** Acquire or renew a runtime lease using a single fenced update. */
export async function leaseRuntime(input: {
  readonly ownerTeamId: string;
  readonly runtimeId: string;
  readonly expectedLeaseGeneration?: number;
  readonly ttlMs: number;
}): Promise<RuntimeRow> {
  const ttlMs = Math.max(1_000, Math.min(Math.floor(input.ttlMs), 15 * 60_000));
  const token = randomUUID();
  const expected = input.expectedLeaseGeneration ?? 0;
  const updated = await updateRuntime({
    ownerTeamId: input.ownerTeamId,
    runtimeId: input.runtimeId,
    expectedLeaseGeneration: expected,
    leaseToken: token,
    leaseExpiresAt: new Date(Date.now() + ttlMs),
  });
  return updated;
}

