import { and, asc, eq, gt, gte, inArray, isNotNull, isNull, lte, ne, or, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeWebhookEvents } from "../../db/schema";

/**
 * The Stripe webhook inbox.
 *
 * A verified event is stored here and answered 2xx at once; processing runs
 * after the response (the webhook's `after()`), and the alerts cron drains
 * whatever that did not finish, with backoff, for as long as Stripe still
 * serves the event.
 *
 * - One event per Stripe object (`objectKey`: the subscription, else the
 *   checkout session or invoice) holds a lease at a time, so two events of one
 *   subscription never apply concurrently and an older read can never commit
 *   after a newer one.
 * - `attempts` counts claims and fences every write: a worker whose lease ran
 *   out and was taken over can no longer complete or fail the event.
 * - A processed event keeps its row as the event-id idempotency record.
 */
export type StripeWebhookInboxEntry = {
  readonly id: string;
  readonly type: string;
  readonly payloadHash: string;
  readonly objectKey: string | null;
  /** Stripe's `event.created`. */
  readonly createdAt: Date | null;
};

/** A leased event. `attempts` includes this attempt and fences the holder's writes. */
export type StripeWebhookClaim = {
  readonly id: string;
  readonly attempts: number;
};

export type StripeWebhookInbox = {
  /**
   * Store a verified event once, or fill a stored copy's missing object key
   * and creation time; answers whether the stored copy was already processed.
   */
  record(entry: StripeWebhookInboxEntry): Promise<{ readonly processed: boolean }>;
  /**
   * Lease an unprocessed event until `leaseUntil`. Null when it is processed,
   * leased, or another event of its object holds a live lease.
   */
  claim(id: string, now: Date, leaseUntil: Date): Promise<StripeWebhookClaim | null>;
  /**
   * The id of an applied event of one of `types` for the same object that
   * Stripe created after this one, if any. Its processing read Stripe's state
   * after this event existed, so this one has nothing newer to apply.
   */
  supersededBy(
    entry: Pick<StripeWebhookInboxEntry, "id" | "objectKey" | "createdAt">,
    types: readonly string[],
  ): Promise<string | null>;
  /** Processed: applied (`skipReason` null) or skipped. False when the claim was lost. */
  complete(claim: StripeWebhookClaim, skipReason: string | null): Promise<boolean>;
  /** Failed: keep the error, release the lease, retry at `nextAttemptAt`. False when the claim was lost. */
  fail(claim: StripeWebhookClaim, error: string, nextAttemptAt: Date): Promise<boolean>;
  /** Unprocessed, unleased events due by `now` and stored since `since`, the longest-waiting first. */
  due(now: Date, since: Date, limit: number): Promise<readonly string[]>;
};

const events = stripeWebhookEvents;
const FIRST_DRAIN_DELAY_SECONDS = 120;

/** The durable inbox: rows of `stripe_webhook_events`. */
export function createDrizzleStripeWebhookInbox(
  db: () => ReturnType<typeof cloudDb> = cloudDb,
): StripeWebhookInbox {
  return {
    async record(entry) {
      // A row stored earlier (a redelivery, or one from before the inbox
      // columns existed) keeps its schedule and gains a missing object key.
      const [row] = await db()
        .insert(events)
        .values({
          id: entry.id,
          type: entry.type,
          payloadHash: entry.payloadHash,
          objectKey: entry.objectKey,
          eventCreatedAt: entry.createdAt,
          // The webhook processes the event itself right after answering;
          // the drain picks it up only if that did not finish.
          nextAttemptAt: sql`now() + make_interval(secs => ${FIRST_DRAIN_DELAY_SECONDS})`,
          // The column's default leases rows the pre-inbox build writes.
          leaseExpiresAt: null,
        })
        .onConflictDoUpdate({
          target: events.id,
          set: {
            objectKey: sql`coalesce(${events.objectKey}, excluded.object_key)`,
            eventCreatedAt: sql`coalesce(${events.eventCreatedAt}, excluded.event_created_at)`,
          },
        })
        .returning({ processedAt: events.processedAt });
      return { processed: Boolean(row?.processedAt) };
    },

    async claim(id, now, leaseUntil) {
      return db().transaction(async (tx) => {
        const [row] = await tx
          .select({
            objectKey: events.objectKey,
            processedAt: events.processedAt,
            leaseExpiresAt: events.leaseExpiresAt,
          })
          .from(events)
          .where(eq(events.id, id))
          .for("update");
        if (!row || row.processedAt) return null;
        if (row.leaseExpiresAt && row.leaseExpiresAt > now) return null;
        if (row.objectKey) {
          // Serialize claims per object: the holder check below runs after any
          // concurrent claim of a sibling event has committed its lease.
          await tx.execute(
            sql`select pg_advisory_xact_lock(hashtextextended(${`stripe:webhook:${row.objectKey}`}, 0))`,
          );
          const [holder] = await tx
            .select({ id: events.id })
            .from(events)
            .where(and(
              eq(events.objectKey, row.objectKey),
              ne(events.id, id),
              isNull(events.processedAt),
              gt(events.leaseExpiresAt, now),
            ))
            .limit(1);
          if (holder) return null;
        }
        if (await heldByPreInboxBuild(tx, id, now)) return null;
        const [claimed] = await tx
          .update(events)
          .set({ attempts: sql`${events.attempts} + 1`, leaseExpiresAt: leaseUntil })
          .where(eq(events.id, id))
          .returning({ attempts: events.attempts });
        return claimed ? { id, attempts: claimed.attempts } : null;
      });
    },

    async supersededBy(entry, types) {
      if (!entry.objectKey || !entry.createdAt || types.length === 0) return null;
      const [row] = await db()
        .select({ id: events.id })
        .from(events)
        .where(and(
          eq(events.objectKey, entry.objectKey),
          ne(events.id, entry.id),
          gt(events.eventCreatedAt, entry.createdAt),
          isNotNull(events.processedAt),
          isNull(events.skipReason),
          inArray(events.type, [...types]),
        ))
        .limit(1);
      return row?.id ?? null;
    },

    async complete(claim, skipReason) {
      const rows = await db()
        .update(events)
        .set({ processedAt: sql`now()`, error: null, skipReason, leaseExpiresAt: null })
        .where(heldBy(claim))
        .returning({ id: events.id });
      return rows.length > 0;
    },

    async fail(claim, error, nextAttemptAt) {
      const rows = await db()
        .update(events)
        .set({ error, leaseExpiresAt: null, nextAttemptAt })
        .where(heldBy(claim))
        .returning({ id: events.id });
      return rows.length > 0;
    },

    async due(now, since, limit) {
      const rows = await db()
        .select({ id: events.id })
        .from(events)
        .where(and(
          isNull(events.processedAt),
          lte(events.nextAttemptAt, now),
          gte(events.createdAt, since),
          or(isNull(events.leaseExpiresAt), lte(events.leaseExpiresAt, now)),
        ))
        .orderBy(asc(events.nextAttemptAt), asc(events.id))
        .limit(limit);
      return rows.map((row) => row.id);
    },
  };
}

type InboxTx = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

/**
 * Rollout barrier. The pre-inbox build stores no object key, so its lease
 * (the column default) cannot be matched to a sibling event; while any row it
 * wrote is still held, the inbox claims nothing. Only that build leaves a
 * live lease with no attempt counted: the inbox stores rows unleased and
 * counts an attempt with every lease it takes. After the cutover this finds
 * nothing within one lease (the partial due index covers the scan).
 */
async function heldByPreInboxBuild(tx: InboxTx, id: string, now: Date): Promise<boolean> {
  const [held] = await tx
    .select({ id: events.id })
    .from(events)
    .where(and(
      isNull(events.processedAt),
      isNull(events.objectKey),
      eq(events.attempts, 0),
      gt(events.leaseExpiresAt, now),
      ne(events.id, id),
    ))
    .limit(1);
  return Boolean(held);
}

function heldBy(claim: StripeWebhookClaim) {
  return and(
    eq(events.id, claim.id),
    eq(events.attempts, claim.attempts),
    isNull(events.processedAt),
  );
}
