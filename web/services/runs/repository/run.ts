import { createHash } from "node:crypto";
import { and, asc, desc, eq, inArray, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { cloudVms, runArtifacts, runAttempts, runEvents, runs } from "../../../db/schema";
import { SANDBOX_VM_DESTROY_CONFIRMED_KEY, SANDBOX_VM_MARKER_KEY, sandboxVmIdempotencyKey, type RunEnvironment } from "../model";
import { RunIdempotencyConflictError, RunNotFoundError, type RunQueryDb } from "./shared";

export type RunSource = { readonly repository?: string; readonly ref?: string; readonly commit?: string; readonly archiveDigest?: string };
export type RunSnapshot = {
  readonly run: typeof runs.$inferSelect;
  readonly attempts: (typeof runAttempts.$inferSelect)[];
  readonly artifacts: (typeof runArtifacts.$inferSelect)[];
  /** Sandboxed Runs only: a VM created under the sandbox's key (or still being created) is not gone yet. */
  readonly sandboxVmLive?: boolean;
  /** Sandboxed Runs only: each VM row created under its key, for the receipt's VM time. */
  readonly sandboxVms?: readonly { readonly createdAt: Date; readonly destroyedAt: Date | null; readonly live: boolean }[];
  /** Sandboxed Runs only: a create the VM reaper abandoned may have made a machine nobody recorded. */
  readonly sandboxVmUnknown?: boolean;
  /** Sandboxed Runs only: the provider ids of its VM rows, redacted wherever its text is shown. */
  readonly sandboxVmHandles?: readonly string[];
};

/**
 * Failure codes of a create that may have reached the provider (services/vms/workflows.ts): the
 * VM reaper's abandoned create, a row update that failed after the provider made the machine
 * (its rollback destroy is best-effort), and a create whose provider cleanup is still pending.
 */
const VM_CREATE_MAYBE_ALLOCATED_CODES = new Set(["create_abandoned", "database_finalize_failed", "provider_create_cleanup_pending"]);

export type CreateRunInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly idempotencyKey?: string | null;
  readonly requestDigest: string;
  readonly source: RunSource;
  readonly recipe: string;
  readonly provider?: string;
  readonly desiredAttempts: number;
  readonly environment?: RunEnvironment;
  /** Required for a sandboxed Run: the manifest image it boots. */
  readonly imageId?: string | null;
  readonly imageVersion?: string | null;
};

export function requestDigest(value: unknown): string {
  return `sha256:${createHash("sha256").update(JSON.stringify(value)).digest("hex")}`;
}

export async function createRun(input: CreateRunInput): Promise<RunSnapshot> {
  if (!Number.isSafeInteger(input.desiredAttempts) || input.desiredAttempts < 1 || input.desiredAttempts > 32) {
    throw new Error("desiredAttempts must be between 1 and 32");
  }
  // The billing team scopes the sandbox's VM; orphan adoption finds a VM by it and its create key.
  if (input.environment === "sandboxed" && (input.desiredAttempts !== 1 || !input.imageId || !input.billingTeamId)) {
    throw new Error("a sandboxed run has exactly one attempt, a pinned image and a billing team");
  }
  const db = cloudDb();
  return db.transaction(async (tx) => {
    const values = {
      userId: input.userId,
      billingTeamId: input.billingTeamId ?? null,
      idempotencyKey: input.idempotencyKey ?? null,
      requestDigest: input.requestDigest,
      source: input.source,
      recipe: input.recipe,
      provider: input.provider ?? "cloud-vm",
      desiredAttempts: input.desiredAttempts,
      environment: input.environment ?? "persistent",
      imageId: input.environment === "sandboxed" ? input.imageId ?? null : null,
      imageVersion: input.environment === "sandboxed" ? input.imageVersion ?? null : null,
    };
    let run: typeof runs.$inferSelect | undefined;
    let inserted = false;
    if (input.idempotencyKey) {
      run = (await tx.insert(runs).values(values).onConflictDoNothing().returning())[0];
      inserted = !!run;
      if (!run) {
        run = (await tx.select().from(runs).where(and(eq(runs.userId, input.userId), eq(runs.idempotencyKey, input.idempotencyKey))).limit(1))[0];
        if (run && run.requestDigest !== input.requestDigest) throw new RunIdempotencyConflictError("idempotency key was already used with a different request");
      }
    } else {
      run = (await tx.insert(runs).values(values).returning())[0];
      inserted = true;
    }
    if (!run) throw new Error("run insert returned no row");
    if (inserted) {
      await tx.insert(runAttempts).values(Array.from({ length: input.desiredAttempts }, (_, ordinal) => ({
        runId: run.id,
        ordinal,
      })));
      await tx.insert(runEvents).values({
        runId: run.id,
        sequence: 1,
        externalId: "run-created",
        kind: "run.created",
        payload: { recipe: run.recipe, desiredAttempts: run.desiredAttempts, environment: run.environment },
      });
    }
    return readSnapshot(tx, run.id, input.userId);
  });
}

export async function readSnapshot(db: RunQueryDb, runId: string, userId: string): Promise<RunSnapshot> {
  const run = (await db.select().from(runs).where(and(eq(runs.id, runId), eq(runs.userId, userId))).limit(1))[0];
  if (!run) throw new RunNotFoundError("run not found");
  const attempts = await db.select().from(runAttempts).where(eq(runAttempts.runId, runId)).orderBy(asc(runAttempts.ordinal));
  const artifacts = await db.select().from(runArtifacts).where(eq(runArtifacts.runId, runId)).orderBy(desc(runArtifacts.createdAt));
  if (run.environment !== "sandboxed" || !run.billingTeamId) return { run, attempts, artifacts };
  // The VM row, not the attempt's handle, says whether a sandbox's machine is gone: a launcher
  // that died between create and journal leaves a VM the attempt never names.
  const keys = attempts.map((attempt) => sandboxVmIdempotencyKey(run.id, attempt.id));
  // The create request carries the marker, so a row still being created (no provider id yet)
  // counts too: until it is destroyed or failed with nothing to clean up, cleanup is pending.
  const rows = keys.length === 0 ? [] : await db.select({
    createdAt: cloudVms.createdAt,
    destroyedAt: cloudVms.destroyedAt,
    status: cloudVms.status,
    providerVmId: cloudVms.providerVmId,
    failureCode: cloudVms.failureCode,
    destroyConfirmed: sql<string | null>`${cloudVms.providerMetadata}->>${SANDBOX_VM_DESTROY_CONFIRMED_KEY}`,
  }).from(cloudVms).where(and(
    eq(cloudVms.billingTeamId, run.billingTeamId),
    eq(cloudVms.userId, run.userId),
    inArray(cloudVms.idempotencyKey, keys),
    // Only the launcher's own rows (marked from their first insert); an unmarked row is not this Run's.
    sql`${cloudVms.providerMetadata}->>${SANDBOX_VM_MARKER_KEY} = ${cloudVms.idempotencyKey}`,
  )).limit(keys.length * 4);
  // A create that failed with no provider id never ran: no VM time, nothing to clean. Except one
  // that failed after the provider call (the VM reaper abandoned it at its deadline, or the row
  // update after a create failed and its rollback destroy is unconfirmed): the machine may exist
  // unrecorded, so the receipt says cleanup is pending and VM time is unknown rather than claim either.
  // A row with no provider id that is still being created (or whose provider cleanup is pending)
  // is unresolved the same way: its machine's lifetime is not the row's.
  const allocationUnknown = rows.some((row) => !row.providerVmId && (row.status !== "failed" || (!!row.failureCode && VM_CREATE_MAYBE_ALLOCATED_CODES.has(row.failureCode))));
  // VM time is measured only on rows the provider gave an id: their lifetime is the machine's.
  const sandboxVms = rows.filter((row) => !!row.providerVmId).map((row) => {
    const confirmedAt = row.destroyConfirmed ? new Date(row.destroyConfirmed) : null;
    const confirmed = !!confirmedAt && !Number.isNaN(confirmedAt.getTime());
    // A destroyed status alone is not proof: a machine the provider made is gone once a strict
    // destroy confirmed it, and its VM time runs until then (to now while unconfirmed).
    const live = row.status !== "destroyed" || (!!row.providerVmId && !confirmed);
    return {
      createdAt: row.createdAt,
      destroyedAt: live ? null : (confirmed && row.providerVmId ? confirmedAt : row.destroyedAt ?? row.createdAt),
      live,
    };
  });
  // The VM rows' provider ids are handles too, journaled on the attempt or not: redacted alike.
  const sandboxVmHandles = rows.flatMap((row) => (row.providerVmId ? [row.providerVmId] : []));
  return { run, attempts, artifacts, sandboxVmLive: allocationUnknown || sandboxVms.some((vm) => vm.live), sandboxVms, sandboxVmUnknown: allocationUnknown, sandboxVmHandles };
}

/** The caller's Run created under `idempotencyKey`, if any (a create retry reads it before resolving its image). */
export async function findRunByIdempotencyKey(userId: string, idempotencyKey: string): Promise<typeof runs.$inferSelect | null> {
  return (await cloudDb().select().from(runs).where(and(eq(runs.userId, userId), eq(runs.idempotencyKey, idempotencyKey))).limit(1))[0] ?? null;
}

export async function getRun(runId: string, userId: string): Promise<RunSnapshot> {
  return readSnapshot(cloudDb(), runId, userId);
}

export async function waitForRun(runId: string, userId: string, waitMs = 0): Promise<RunSnapshot> {
  const deadline = Date.now() + Math.max(0, Math.min(waitMs, 10_000));
  for (;;) {
    const snapshot = await getRun(runId, userId);
    if (["succeeded", "failed", "cancelled"].includes(snapshot.run.status) || Date.now() >= deadline) return snapshot;
    await new Promise((resolve) => setTimeout(resolve, Math.min(250, Math.max(1, deadline - Date.now()))));
  }
}
