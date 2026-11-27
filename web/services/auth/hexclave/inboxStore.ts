import { randomUUID } from "node:crypto";
import { and, eq, inArray, isNotNull, lt, lte, or, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import {
  hexclaveWebhookEvents,
  hexclaveWebhookInbox,
  hexclaveWebhookInboxDrainSlots,
  hexclaveWebhookInboxState,
} from "../../../db/schema";
import type { DrainSlotLease, HexclaveInboxEntry, HexclaveInboxStore } from "./inbox";

type InboxDb = ReturnType<typeof cloudDb>;
type InboxTx = Parameters<Parameters<InboxDb["transaction"]>[0]>[0];

const inbox = hexclaveWebhookInbox;
const slots = hexclaveWebhookInboxDrainSlots;
const state = hexclaveWebhookInboxState;
const DRAIN_GATE_LOCK_KEY = "hexclave:inbox:drain-gate";

const timestamp = (at: Date) => sql`${at.toISOString()}::timestamptz`;

/** The durable store behind the Hexclave webhook inbox. */
export function createDrizzleHexclaveInboxStore(db: () => InboxDb = cloudDb): HexclaveInboxStore {
  return {
    async enqueue({ svixId, eventType, target }) {
      await db()
        .insert(inbox)
        .values({
          svixId,
          eventType,
          entityKind: target.kind,
          entityId: target.id,
          revokeCandidateTeamIds: [...target.revokeCandidateTeamIds],
        })
        .onConflictDoNothing({ target: inbox.svixId });
    },

    async claimDrainSlot(now, leaseUntil, slotCount): Promise<DrainSlotLease | null> {
      return db().transaction(async (tx) => {
        // Serialize the backoff check with a transient failure installing its
        // throttle; no drain can slip through between those two writes.
        await lockDrainGate(tx);
        const [held] = await tx
          .select({ throttledUntil: state.throttledUntil })
          .from(state)
          .where(eq(state.id, 1));
        if (held && held.throttledUntil > now) return null;
        for (let slot = 0; slot < slotCount; slot++) {
          const leaseId = randomUUID();
          const [row] = await tx
            .insert(slots)
            .values({ slot, leaseId, leasedUntil: leaseUntil })
            .onConflictDoUpdate({
              target: slots.slot,
              set: { leaseId, leasedUntil: leaseUntil },
              setWhere: lte(slots.leasedUntil, now),
            })
            .returning({ slot: slots.slot, leaseId: slots.leaseId });
          if (row) return { slot: row.slot, leaseId: row.leaseId };
        }
        return null;
      });
    },

    async releaseDrainSlot({ slot, leaseId }) {
      await db()
        .update(slots)
        .set({ leasedUntil: new Date(0) })
        .where(and(eq(slots.slot, slot), eq(slots.leaseId, leaseId)));
    },

    async throttleUntil(until) {
      await db().transaction(async (tx) => {
        await lockDrainGate(tx);
        await tx
          .insert(state)
          .values({ id: 1, throttledUntil: until })
          .onConflictDoUpdate({
            target: state.id,
            set: { throttledUntil: sql`greatest(${state.throttledUntil}, excluded.throttled_until)` },
          });
      });
    },

    async claimDue(now, entityLimit, leaseUntil): Promise<readonly HexclaveInboxEntry[]> {
      return db().transaction(async (tx) => {
        const at = timestamp(now);
        const candidateResult = await tx.execute(sql`
          select candidate.entity_kind, candidate.entity_id
          from ${inbox} as candidate
          where candidate.dead_lettered_at is null
            and candidate.next_attempt_at <= ${at}
            and (candidate.claimed_until is null or candidate.claimed_until <= ${at})
            and not exists (
              select 1 from ${inbox} as active
              where active.entity_kind = candidate.entity_kind
                and active.entity_id = candidate.entity_id
                and active.dead_lettered_at is null
                and active.claimed_until > ${at}
            )
          group by candidate.entity_kind, candidate.entity_id
          order by min(candidate.received_at), candidate.entity_kind, candidate.entity_id
          limit ${entityLimit}
        `);
        const candidates = databaseRows(candidateResult) as readonly EntityRow[];
        if (candidates.length === 0) return [];

        // The lock statement and update intentionally use separate READ
        // COMMITTED snapshots. If a heartbeat wins the entity lock and
        // commits a renewal after candidate selection, the update below sees
        // that fresh active claim and refuses every row for the entity.
        const lockResult = await tx.execute(sql`
          select candidate.entity_kind, candidate.entity_id,
            pg_try_advisory_xact_lock(hashtextextended(
              'hexclave:inbox:' || candidate.entity_kind || ':' || candidate.entity_id,
              0
            )) as acquired
          from (values ${sql.join(candidates.map((candidate) => sql`(${candidate.entity_kind}, ${candidate.entity_id})`), sql`, `)})
            as candidate(entity_kind, entity_id)
          order by candidate.entity_kind, candidate.entity_id
        `);
        const locked = (databaseRows(lockResult) as readonly LockedEntityRow[]).filter((row) => row.acquired);
        if (locked.length === 0) return [];

        const result = await tx.execute(sql`
          with eligible as materialized (
            select picked.entity_kind, picked.entity_id
            from (values ${sql.join(locked.map((candidate) => sql`(${candidate.entity_kind}, ${candidate.entity_id})`), sql`, `)})
              as picked(entity_kind, entity_id)
            where not exists (
              select 1 from ${inbox} as active
              where active.entity_kind = picked.entity_kind
                and active.entity_id = picked.entity_id
                and active.dead_lettered_at is null
                and active.claimed_until > ${at}
            )
          )
          update ${inbox} as entry
          set claimed_until = ${timestamp(leaseUntil)}
          from eligible
          where entry.entity_kind = eligible.entity_kind
            and entry.entity_id = eligible.entity_id
            and entry.dead_lettered_at is null
            and entry.next_attempt_at <= ${at}
            and (entry.claimed_until is null or entry.claimed_until <= ${at})
          returning entry.svix_id, entry.event_type, entry.entity_kind, entry.entity_id,
            entry.revoke_candidate_team_ids, entry.attempts, entry.claimed_until
        `);
        return (databaseRows(result) as readonly ClaimedRow[]).slice()
          .sort((a, b) => a.svix_id.localeCompare(b.svix_id))
          .map((row) => ({
            svixId: row.svix_id,
            eventType: row.event_type,
            target: { kind: row.entity_kind, id: row.entity_id, revokeCandidateTeamIds: row.revoke_candidate_team_ids ?? [] },
            attempts: row.attempts,
            claimUntil: new Date(row.claimed_until),
          }));
      });
    },

    async renewClaims(svixIds, expectedUntil, nextUntil) {
      return mutateOwnedClaims(db(), svixIds, expectedUntil, (tx) =>
        tx.update(inbox).set({ claimedUntil: nextUntil }).where(inArray(inbox.svixId, [...svixIds])));
    },

    async complete(svixIds, expectedUntil) {
      return mutateOwnedClaims(db(), svixIds, expectedUntil, (tx) =>
        tx.delete(inbox).where(inArray(inbox.svixId, [...svixIds])));
    },

    async recordFailure(svixIds, expectedUntil, { now, nextAttemptAt, error, maxAttempts, throttleUntil }) {
      return mutateOwnedClaims(db(), svixIds, expectedUntil, async (tx) => {
        await tx
          .update(inbox)
          .set({
            attempts: sql`${inbox.attempts} + 1`,
            nextAttemptAt,
            claimedUntil: null,
            lastError: error.slice(0, 300),
            deadLetteredAt: sql`case when ${inbox.attempts} + 1 >= ${maxAttempts} then ${timestamp(now)} else null end`,
          })
          .where(inArray(inbox.svixId, [...svixIds]));
        if (throttleUntil) {
          await tx
            .insert(state)
            .values({ id: 1, throttledUntil: throttleUntil })
            .onConflictDoUpdate({
              target: state.id,
              set: { throttledUntil: sql`greatest(${state.throttledUntil}, excluded.throttled_until)` },
            });
        }
      }, { drainGate: throttleUntil !== undefined });
    },

    async defer(svixIds, expectedUntil, nextAttemptAt) {
      return mutateOwnedClaims(db(), svixIds, expectedUntil, (tx) =>
        tx.update(inbox).set({ nextAttemptAt, claimedUntil: null }).where(inArray(inbox.svixId, [...svixIds])));
    },

    async health(attempts) {
      const [row] = await db()
        .select({
          stuck: sql<number>`count(*) filter (where ${inbox.deadLetteredAt} is null and ${inbox.attempts} >= ${attempts})::int`,
          deadLettered: sql<number>`count(*) filter (where ${inbox.deadLetteredAt} is not null)::int`,
        })
        .from(inbox);
      return { stuck: row?.stuck ?? 0, deadLettered: row?.deadLettered ?? 0 };
    },

    async recordReportedHealth({ stuck, deadLettered }) {
      // Insert-or-update only when the counts differ; a returned row means changed.
      const changed = await db()
        .insert(state)
        .values({ id: 1, reportedStuck: stuck, reportedDeadLettered: deadLettered })
        .onConflictDoUpdate({
          target: state.id,
          set: { reportedStuck: stuck, reportedDeadLettered: deadLettered },
          setWhere: or(
            sql`${state.reportedStuck} <> ${stuck}`,
            sql`${state.reportedDeadLettered} <> ${deadLettered}`,
          ),
        })
        .returning({ id: state.id });
      return changed.length > 0;
    },

    async purgeProcessedEvents(olderThan) {
      // Svix stops redelivering long before this, so the idempotency record
      // of an applied event is no longer needed.
      const deleted = await db()
        .delete(hexclaveWebhookEvents)
        .where(and(isNotNull(hexclaveWebhookEvents.processedAt), lt(hexclaveWebhookEvents.processedAt, olderThan)))
        .returning({ svixId: hexclaveWebhookEvents.svixId });
      return deleted.length;
    },

    async purgeDeadLettered(olderThan) {
      const deleted = await db()
        .delete(inbox)
        .where(and(isNotNull(inbox.deadLetteredAt), lt(inbox.deadLetteredAt, olderThan)))
        .returning({ svixId: inbox.svixId });
      return deleted.length;
    },
  };
}

/** Lock and verify every row before mutating any of them. */
async function mutateOwnedClaims(
  database: InboxDb,
  svixIds: readonly string[],
  expectedUntil: Date,
  mutate: (tx: InboxTx) => Promise<unknown>,
  options: { readonly drainGate?: boolean } = {},
): Promise<boolean> {
  if (svixIds.length === 0) return true;
  return database.transaction(async (tx) => {
    if (options.drainGate) await lockDrainGate(tx);
    // Claim establishment takes the same entity locks before touching rows.
    // Read immutable entity identities first so this transaction can follow
    // that lock order and never deadlock a concurrent claimDue statement.
    const claims = await tx
      .select({ kind: inbox.entityKind, id: inbox.entityId })
      .from(inbox)
      .where(inArray(inbox.svixId, [...svixIds]));
    if (claims.length !== svixIds.length) return false;
    const entityKeys = [...new Set(claims.map((claim) => `hexclave:inbox:${claim.kind}:${claim.id}`))].sort();
    for (const key of entityKeys) {
      // claimDue never waits for this lock. A mutation does: a competing
      // claim may hold it briefly only to recheck and discover this live
      // lease. After that transaction commits, the exact token below tells
      // whether this worker still owns the rows or actually lost them.
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${key}, 0))`);
    }
    const owned = await tx
      .select({ svixId: inbox.svixId })
      .from(inbox)
      .where(and(inArray(inbox.svixId, [...svixIds]), eq(inbox.claimedUntil, expectedUntil)))
      .orderBy(inbox.svixId)
      .for("update");
    if (owned.length !== svixIds.length) return false;
    await mutate(tx);
    return true;
  });
}

async function lockDrainGate(tx: InboxTx): Promise<void> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${DRAIN_GATE_LOCK_KEY}, 0))`);
}

type ClaimedRow = {
  readonly svix_id: string;
  readonly event_type: string;
  readonly entity_kind: "user" | "team";
  readonly entity_id: string;
  readonly revoke_candidate_team_ids: string[] | null;
  readonly attempts: number;
  readonly claimed_until: string | Date;
};

type EntityRow = {
  readonly entity_kind: "user" | "team";
  readonly entity_id: string;
};

type LockedEntityRow = EntityRow & { readonly acquired: boolean };

/** `execute` answers an array (postgres-js) or `{ rows }` (node-postgres). */
function databaseRows(result: unknown): readonly Record<string, unknown>[] {
  if (Array.isArray(result)) return result as Record<string, unknown>[];
  const rows = (result as { rows?: unknown } | null)?.rows;
  return Array.isArray(rows) ? rows as Record<string, unknown>[] : [];
}
