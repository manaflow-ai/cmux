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

type InboxDb = Pick<ReturnType<typeof cloudDb>, "select" | "insert" | "update" | "delete" | "execute">;

const inbox = hexclaveWebhookInbox;
const slots = hexclaveWebhookInboxDrainSlots;
const state = hexclaveWebhookInboxState;

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
      // The global Hexclave backoff gates every drain before it touches a slot.
      const [held] = await db()
        .select({ throttledUntil: state.throttledUntil })
        .from(state)
        .where(eq(state.id, 1));
      if (held && held.throttledUntil > now) return null;
      for (let slot = 0; slot < slotCount; slot++) {
        const leaseId = randomUUID();
        const [row] = await db()
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
    },

    async releaseDrainSlot({ slot, leaseId }) {
      await db()
        .update(slots)
        .set({ leasedUntil: new Date(0) })
        .where(and(eq(slots.slot, slot), eq(slots.leaseId, leaseId)));
    },

    async throttleUntil(until) {
      await db()
        .insert(state)
        .values({ id: 1, throttledUntil: until })
        .onConflictDoUpdate({
          target: state.id,
          set: { throttledUntil: sql`greatest(${state.throttledUntil}, excluded.throttled_until)` },
        });
    },

    async claimDue(now, entityLimit, leaseUntil): Promise<readonly HexclaveInboxEntry[]> {
      // Pick the oldest entities with due work, then claim all of their due
      // entries in one update. The update re-checks the claim under the row
      // lock, so a concurrent drain that picked the same entity claims nothing.
      const at = timestamp(now);
      const result = await db().execute(sql`
        with picked as (
          select entity_kind, entity_id
          from ${inbox}
          where dead_lettered_at is null
            and next_attempt_at <= ${at}
            and (claimed_until is null or claimed_until <= ${at})
          group by entity_kind, entity_id
          order by min(received_at), entity_kind, entity_id
          limit ${entityLimit}
        )
        update ${inbox} as entry
        set claimed_until = ${timestamp(leaseUntil)}
        from picked
        where entry.entity_kind = picked.entity_kind
          and entry.entity_id = picked.entity_id
          and entry.dead_lettered_at is null
          and entry.next_attempt_at <= ${at}
          and (entry.claimed_until is null or entry.claimed_until <= ${at})
        returning entry.svix_id, entry.event_type, entry.entity_kind, entry.entity_id,
          entry.revoke_candidate_team_ids, entry.attempts
      `);
      return (databaseRows(result) as readonly ClaimedRow[]).slice()
        .sort((a, b) => a.svix_id.localeCompare(b.svix_id))
        .map((row) => ({
          svixId: row.svix_id,
          eventType: row.event_type,
          target: { kind: row.entity_kind, id: row.entity_id, revokeCandidateTeamIds: row.revoke_candidate_team_ids ?? [] },
          attempts: row.attempts,
        }));
    },

    async complete(svixIds) {
      if (svixIds.length === 0) return;
      await db().delete(inbox).where(inArray(inbox.svixId, [...svixIds]));
    },

    async recordFailure(svixIds, { now, nextAttemptAt, error, maxAttempts }) {
      if (svixIds.length === 0) return;
      await db()
        .update(inbox)
        .set({
          attempts: sql`${inbox.attempts} + 1`,
          nextAttemptAt,
          claimedUntil: null,
          lastError: error.slice(0, 300),
          deadLetteredAt: sql`case when ${inbox.attempts} + 1 >= ${maxAttempts} then ${timestamp(now)} else null end`,
        })
        .where(inArray(inbox.svixId, [...svixIds]));
    },

    async defer(svixIds, nextAttemptAt) {
      if (svixIds.length === 0) return;
      await db()
        .update(inbox)
        .set({ nextAttemptAt, claimedUntil: null })
        .where(inArray(inbox.svixId, [...svixIds]));
    },

    async purgeEntity({ kind, id }) {
      await db().delete(inbox).where(and(eq(inbox.entityKind, kind), eq(inbox.entityId, id)));
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

type ClaimedRow = {
  readonly svix_id: string;
  readonly event_type: string;
  readonly entity_kind: "user" | "team";
  readonly entity_id: string;
  readonly revoke_candidate_team_ids: string[] | null;
  readonly attempts: number;
};

/** `execute` answers an array (postgres-js) or `{ rows }` (node-postgres). */
function databaseRows(result: unknown): readonly Record<string, unknown>[] {
  if (Array.isArray(result)) return result as Record<string, unknown>[];
  const rows = (result as { rows?: unknown } | null)?.rows;
  return Array.isArray(rows) ? rows as Record<string, unknown>[] : [];
}
