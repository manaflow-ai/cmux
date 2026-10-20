import { and, eq, lt, sql } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { cloudDb } from "../../db/client";
import { cloudVmSnapshotRequests } from "../../db/schema";
import type { SnapshotRef } from "./drivers";
import { VmDatabaseError } from "./errors";

/** What a snapshot request with an idempotency key may do next. */
export type SnapshotRequestBegin =
  | { readonly kind: "started" }
  | { readonly kind: "succeeded"; readonly snapshot: SnapshotRef }
  | { readonly kind: "in_progress" }
  | { readonly kind: "conflict" };

export type SnapshotRequestOutcome =
  | { readonly kind: "succeeded"; readonly snapshot: SnapshotRef }
  | { readonly kind: "failed" };

export type BeginSnapshotRequestInput = {
  /** `cloud_vms.id` of the machine (not the provider id). */
  readonly vmId: string;
  readonly idempotencyKey: string;
  readonly name: string | null;
  /** A pending row last touched before this instant belongs to a dead attempt. */
  readonly staleBefore: Date;
};

export type FinishSnapshotRequestInput = {
  readonly vmId: string;
  readonly idempotencyKey: string;
  readonly outcome: SnapshotRequestOutcome;
};

function dbEffect<A>(operation: string, run: () => Promise<A>): Effect.Effect<A, VmDatabaseError> {
  return Effect.tryPromise({ try: run, catch: (cause) => new VmDatabaseError({ operation, cause }) });
}

/**
 * Claims (machine, key). The insert and the stale takeover are single
 * statements, so two concurrent retries cannot both start a snapshot.
 */
export function beginSnapshotRequest(input: BeginSnapshotRequestInput): Effect.Effect<SnapshotRequestBegin, VmDatabaseError> {
  return dbEffect("beginSnapshotRequest", async () => {
    const db = cloudDb();
    const table = cloudVmSnapshotRequests;
    const inserted = await db
      .insert(table)
      .values({ vmId: input.vmId, idempotencyKey: input.idempotencyKey, name: input.name, status: "pending" })
      .onConflictDoNothing()
      .returning({ vmId: table.vmId });
    if (inserted.length > 0) return { kind: "started" };
    const match = and(eq(table.vmId, input.vmId), eq(table.idempotencyKey, input.idempotencyKey));
    const takenOver = await db
      .update(table)
      .set({ updatedAt: sql`clock_timestamp()` })
      .where(and(
        match,
        eq(table.status, "pending"),
        sql`${table.name} is not distinct from ${input.name}`,
        lt(table.updatedAt, input.staleBefore),
      ))
      .returning({ vmId: table.vmId });
    if (takenOver.length > 0) return { kind: "started" };
    const [row] = await db.select().from(table).where(match).limit(1);
    // The row was deleted (a failed attempt) between the insert and now: the
    // caller retries and claims it.
    if (!row) return { kind: "in_progress" };
    if ((row.name ?? null) !== input.name) return { kind: "conflict" };
    if (row.status === "succeeded" && row.providerSnapshotId && row.snapshotCreatedAtMs !== null) {
      return {
        kind: "succeeded",
        snapshot: {
          id: row.providerSnapshotId,
          createdAt: row.snapshotCreatedAtMs,
          ...(row.snapshotName ? { name: row.snapshotName } : {}),
        },
      };
    }
    return { kind: "in_progress" };
  });
}

/** Records the provider result, or frees the key after a failure. */
export function finishSnapshotRequest(input: FinishSnapshotRequestInput): Effect.Effect<void, VmDatabaseError> {
  return dbEffect("finishSnapshotRequest", async () => {
    const db = cloudDb();
    const table = cloudVmSnapshotRequests;
    const match = and(eq(table.vmId, input.vmId), eq(table.idempotencyKey, input.idempotencyKey), eq(table.status, "pending"));
    if (input.outcome.kind === "failed") {
      await db.delete(table).where(match);
      return;
    }
    const snapshot = input.outcome.snapshot;
    await db
      .update(table)
      .set({
        status: "succeeded",
        providerSnapshotId: snapshot.id,
        snapshotName: snapshot.name ?? null,
        snapshotCreatedAtMs: snapshot.createdAt,
        updatedAt: sql`clock_timestamp()`,
      })
      .where(match);
  });
}
