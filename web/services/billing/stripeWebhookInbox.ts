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
  /** Store a verified event once; answers whether a stored copy was already processed. */
  record(entry: StripeWebhookInboxEntry): Promise<{ readonly processed: boolean }>;
  /**
   * Lease an unprocessed event until `leaseUntil`. Null when it is processed,
   * leased, or another event of its object holds a live lease.
   */
  claim(id: string, now: Date, leaseUntil: Date): Promise<StripeWebhookClaim | null>;
  /** Hold database row/object locks for the entire effect, beyond any lease deadline. */
  runExclusive<T>(claim: StripeWebhookClaim, objectKey: string | null,
    operation: (inbox: StripeWebhookInbox) => Promise<T>): Promise<T | null>;
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
      const [inserted] = await db()
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
        })
        .onConflictDoNothing({ target: events.id })
        .returning({ id: events.id });
      if (inserted) return { processed: false };
      const [existing] = await db()
        .select({ processedAt: events.processedAt })
        .from(events)
        .where(eq(events.id, entry.id))
        .limit(1);
      return { processed: Boolean(existing?.processedAt) };
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
          .for("update", { skipLocked: true });
        if (!row || row.processedAt) return null;
        if (row.leaseExpiresAt && row.leaseExpiresAt > now) return null;
        if (row.objectKey) {
          // Serialize claims per object: the holder check below runs after any
          // concurrent claim of a sibling event has committed its lease.
          const lock = await tx.execute<{ locked: boolean }>(
            sql`select pg_try_advisory_xact_lock(hashtextextended(${`stripe:webhook:${row.objectKey}`}, 0)) as locked`,
          );
          if (!lock[0]?.locked) return null;
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
        const [claimed] = await tx
          .update(events)
          .set({ attempts: sql`${events.attempts} + 1`, leaseExpiresAt: leaseUntil })
          .where(eq(events.id, id))
          .returning({ attempts: events.attempts });
        return claimed ? { id, attempts: claimed.attempts } : null;
      });
    },

    async runExclusive(claim, objectKey, operation) {
      return db().transaction(async (tx) => {
        // No expiry can transfer this event while its effects are running. A
        // crashed process releases the transaction lock; a slow one keeps it.
        const [row] = await tx.select({ attempts: events.attempts, processedAt: events.processedAt })
          .from(events).where(eq(events.id, claim.id)).for("update", { skipLocked: true });
        if (!row || row.processedAt || row.attempts !== claim.attempts) return null;
        if (objectKey) {
          const lock = await tx.execute<{ locked: boolean }>(
            sql`select pg_try_advisory_xact_lock(hashtextextended(${`stripe:webhook:${objectKey}`}, 0)) as locked`,
          );
          if (!lock[0]?.locked) return null;
          const [holder] = await tx.select({ id: events.id }).from(events).where(and(
            eq(events.objectKey, objectKey), ne(events.id, claim.id), isNull(events.processedAt),
            gt(events.leaseExpiresAt, sql`now()`),
          )).limit(1);
          if (holder) return null;
        }
        await tx.update(events).set({ objectKey }).where(eq(events.id, claim.id));
        // Completion/failure belongs to this same transaction, so it cannot
        // block on the row lock the callback owns.
        return operation(createDrizzleStripeWebhookInbox(() => tx as ReturnType<typeof cloudDb>));
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

function heldBy(claim: StripeWebhookClaim) {
  return and(
    eq(events.id, claim.id),
    eq(events.attempts, claim.attempts),
    isNull(events.processedAt),
  );
}
