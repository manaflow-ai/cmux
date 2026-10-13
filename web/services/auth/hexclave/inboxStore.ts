import { and, eq, gte, inArray, lte, sql } from "drizzle-orm";
import { cloudDb } from "../../../db/client";
import { hexclaveWebhookInbox, hexclaveWebhookInboxDrainSlots } from "../../../db/schema";
import type { HexclaveInboxEntry, HexclaveInboxStore } from "./inbox";

type InboxDb = Pick<ReturnType<typeof cloudDb>, "select" | "insert" | "update" | "delete" | "execute">;

const inbox = hexclaveWebhookInbox;
const slots = hexclaveWebhookInboxDrainSlots;

/** The durable store behind the Hexclave webhook inbox. */
export function createDrizzleHexclaveInboxStore(db: () => InboxDb = cloudDb): HexclaveInboxStore {
  return {
    async enqueue({ svixId, eventType, target, payload }) {
      await db()
        .insert(inbox)
        .values({
          svixId,
          eventType,
          entityKind: target.kind,
          entityId: target.id,
          revokeCandidateTeamIds: [...target.revokeCandidateTeamIds],
          payload,
        })
        .onConflictDoNothing({ target: inbox.svixId });
    },

    async claimDrainSlot(now, leaseUntil, slotCount) {
      for (let slot = 0; slot < slotCount; slot++) {
        const [row] = await db()
          .insert(slots)
          .values({ slot, leasedUntil: leaseUntil })
          .onConflictDoUpdate({
            target: slots.slot,
            set: { leasedUntil: leaseUntil },
            setWhere: lte(slots.leasedUntil, now),
          })
          .returning({ slot: slots.slot });
        if (row) return row.slot;
      }
      return null;
    },

    async releaseDrainSlot(slot) {
      await db().update(slots).set({ leasedUntil: new Date(0) }).where(eq(slots.slot, slot));
    },

    async claimDue(now, entityLimit, leaseUntil): Promise<readonly HexclaveInboxEntry[]> {
      // Pick the oldest entities with due work, then claim all of their due
      // entries in one update. The update re-checks the claim under the row
      // lock, so a concurrent drain that picked the same entity claims nothing.
      const at = sql`${now.toISOString()}::timestamptz`;
      const lease = sql`${leaseUntil.toISOString()}::timestamptz`;
      const result = await db().execute(sql`
        with picked as (
          select entity_kind, entity_id
          from ${inbox}
          where next_attempt_at <= ${at} and (claimed_until is null or claimed_until <= ${at})
          group by entity_kind, entity_id
          order by min(received_at), entity_kind, entity_id
          limit ${entityLimit}
        )
        update ${inbox} as entry
        set claimed_until = ${lease}
        from picked
        where entry.entity_kind = picked.entity_kind
          and entry.entity_id = picked.entity_id
          and entry.next_attempt_at <= ${at}
          and (entry.claimed_until is null or entry.claimed_until <= ${at})
        returning entry.svix_id, entry.event_type, entry.entity_kind, entry.entity_id,
          entry.revoke_candidate_team_ids, entry.attempts, entry.received_at
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

    async retryLater(svixIds, { nextAttemptAt, error }) {
      if (svixIds.length === 0) return;
      await db()
        .update(inbox)
        .set({
          attempts: sql`${inbox.attempts} + 1`,
          nextAttemptAt,
          claimedUntil: null,
          lastError: error.slice(0, 300),
        })
        .where(inArray(inbox.svixId, [...svixIds]));
    },

    async countStuck(attempts) {
      const [row] = await db()
        .select({ count: sql<number>`count(*)::int` })
        .from(inbox)
        .where(and(gte(inbox.attempts, attempts)));
      return row?.count ?? 0;
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
