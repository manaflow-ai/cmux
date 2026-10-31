import { and, eq, sql } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { cloudDb } from "../../db/client";
import { cloudVmSnapshotRequests, cloudVmUsageEvents } from "../../db/schema";
import type { SnapshotRef } from "./drivers";
import { VmDatabaseError } from "./errors";

/** What a snapshot request with an idempotency key may do next. */
export type SnapshotRequestBegin =
  | { readonly kind: "started" }
  | { readonly kind: "succeeded"; readonly snapshot: SnapshotRef }
  | { readonly kind: "in_progress" }
  | { readonly kind: "conflict" }
  | { readonly kind: "quota_exceeded"; readonly limit: number };

export type SnapshotRequestOutcome =
  | { readonly kind: "succeeded"; readonly snapshot: SnapshotRef }
  | { readonly kind: "rejected" };

export type BeginSnapshotRequestInput = {
  /** `cloud_vms.id` of the machine (not the provider id). */
  readonly vmId: string;
  readonly idempotencyKey: string;
  readonly name: string | null;
  /** Maximum provider snapshots retained for this machine. */
  readonly maxSnapshots: number;
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
 * Claims (machine, key). A pending row is permanent until the machine is
 * deleted: a provider timeout is ambiguous and must never authorize another
 * non-idempotent snapshot call with the same key.
 */
export function beginSnapshotRequest(input: BeginSnapshotRequestInput): Effect.Effect<SnapshotRequestBegin, VmDatabaseError> {
  return dbEffect("beginSnapshotRequest", async () => {
    const db = cloudDb();
    const table = cloudVmSnapshotRequests;
    const limit = Math.max(1, Math.trunc(input.maxSnapshots));
    return db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`vm-snapshots:${input.vmId}`}, 0))`);
      const match = and(eq(table.vmId, input.vmId), eq(table.idempotencyKey, input.idempotencyKey));
      const [existing] = await tx.select().from(table).where(match).limit(1);
      if (existing) {
        if ((existing.name ?? null) !== input.name) return { kind: "conflict" };
        if (existing.status === "succeeded" && existing.providerSnapshotId && existing.snapshotCreatedAtMs !== null) {
          return {
            kind: "succeeded",
            snapshot: {
              id: existing.providerSnapshotId,
              createdAt: existing.snapshotCreatedAtMs,
              ...(existing.snapshotName ? { name: existing.snapshotName } : {}),
            },
          };
        }
        return { kind: "in_progress" };
      }

      const countRows = await tx.execute(sql`
        with active_snapshots as (
          select distinct created.metadata->>'snapshotId' as snapshot_id
          from ${cloudVmUsageEvents} as created
          where created.vm_id = ${input.vmId}::uuid
            and created.event_type = 'vm.snapshot.created'
            and nullif(created.metadata->>'snapshotId', '') is not null
            and not exists (
              select 1 from ${cloudVmUsageEvents} as deleted
              where deleted.vm_id = created.vm_id
                and deleted.event_type = 'vm.snapshot.deleted'
                and deleted.metadata->>'snapshotId' = created.metadata->>'snapshotId'
            )
        ), request_reservations as (
          select case
            when request.status = 'succeeded' and request.provider_snapshot_id is not null
              then 'snapshot:' || request.provider_snapshot_id
            else 'request:' || request.idempotency_key
          end as slot
          from ${table} as request
          where request.vm_id = ${input.vmId}::uuid
            and (
              request.status = 'pending'
              or (
                request.status = 'succeeded'
                and request.provider_snapshot_id is not null
                and not exists (
                  select 1 from ${cloudVmUsageEvents} as deleted
                  where deleted.vm_id = request.vm_id
                    and deleted.event_type = 'vm.snapshot.deleted'
                    and deleted.metadata->>'snapshotId' = request.provider_snapshot_id
                )
              )
            )
        ), quota_slots as (
          select 'snapshot:' || snapshot_id as slot from active_snapshots
          union
          select slot from request_reservations
        )
        select count(*)::int as count from quota_slots
      `);
      if (Number(countRows[0]?.count ?? 0) >= limit) return { kind: "quota_exceeded", limit };

      const inserted = await tx
        .insert(table)
        .values({ vmId: input.vmId, idempotencyKey: input.idempotencyKey, name: input.name, status: "pending" })
        .onConflictDoNothing()
        .returning({ vmId: table.vmId });
      return inserted.length > 0 ? { kind: "started" } : { kind: "in_progress" };
    });
  });
}

/** Records a confirmed provider result. Ambiguous failures keep their reservation. */
export function finishSnapshotRequest(input: FinishSnapshotRequestInput): Effect.Effect<void, VmDatabaseError> {
  return dbEffect("finishSnapshotRequest", async () => {
    const db = cloudDb();
    const table = cloudVmSnapshotRequests;
    const match = and(eq(table.vmId, input.vmId), eq(table.idempotencyKey, input.idempotencyKey), eq(table.status, "pending"));
    if (input.outcome.kind === "rejected") {
      // Only a definitive provider refusal reaches this branch. Transport
      // errors and timeouts never call finish, so their pending fence remains.
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
