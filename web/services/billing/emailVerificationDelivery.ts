import { eq, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { billingEmailVerificationDeliveries } from "../../db/schema";

const ATTEMPT_LEASE_MS = 2 * 60 * 1000;
// If the provider accepted a request but the connection failed before the
// response arrived, do not send a second message for the same purchase later.
// The user can still request a fresh link from the normal Stack sign-in page.
const AMBIGUOUS_RETRY_WINDOW_MS = 23 * 60 * 60 * 1000;

export type PurchaseMagicLinkDeliveryInput = {
  readonly checkoutSessionId: string;
  readonly stackUserId: string;
  /** Canonical address used as the durable ownership key. */
  readonly email: string;
};

export type PurchaseMagicLinkDeliveryResult =
  | "sent"
  | "already_sent"
  | "delivery_in_progress"
  | "delivery_abandoned";

export type PurchaseMagicLinkDeliveryStore = {
  deliverOnce(
    input: PurchaseMagicLinkDeliveryInput,
    deliver: () => Promise<void>,
  ): Promise<PurchaseMagicLinkDeliveryResult>;
};

/** A provider response that proves no message was accepted. */
export class PurchaseMagicLinkProviderRejectedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PurchaseMagicLinkProviderRejectedError";
  }
}

type DeliveryDb = Pick<ReturnType<typeof cloudDb>, "transaction">;

/** Build the production store. The database is the cross-instance idempotency authority. */
export function makePurchaseMagicLinkDeliveryStore(
  db: DeliveryDb = cloudDb(),
): PurchaseMagicLinkDeliveryStore {
  return {
    deliverOnce: async (input, deliver) => {
      const claimedAt = new Date();
      const claim = await claimDelivery(db, input, claimedAt);
      if (claim !== "claimed") return claim;

      // The provider call intentionally runs after the claim transaction has
      // committed. An unresolved started-at marker also fences retries after
      // the short lease expires, because Stack has no idempotency-key API.
      try {
        await deliver();
      } catch (error) {
        // Only a response that proves rejection is safe to retry. A timeout,
        // connection reset, or process crash may have happened after Stack
        // accepted the request, so its marker stays until the provider window.
        if (error instanceof PurchaseMagicLinkProviderRejectedError) {
          await releaseDeliveryAttempt(db, input, new Date());
        }
        throw error;
      }
      await markDeliverySent(db, input, new Date());
      return "sent";
    },
  };
}

async function claimDelivery(
  db: DeliveryDb,
  input: PurchaseMagicLinkDeliveryInput,
  claimedAt: Date,
): Promise<"claimed" | Exclude<PurchaseMagicLinkDeliveryResult, "sent">> {
  return await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${deliveryLockKey(input.checkoutSessionId)}, 0))`,
    );
    const [existing] = await tx
      .select({
        stackUserId: billingEmailVerificationDeliveries.stackUserId,
        email: billingEmailVerificationDeliveries.email,
        deliveryStartedAt: billingEmailVerificationDeliveries.deliveryStartedAt,
        attemptLeaseExpiresAt:
          billingEmailVerificationDeliveries.attemptLeaseExpiresAt,
        sentAt: billingEmailVerificationDeliveries.sentAt,
      })
      .from(billingEmailVerificationDeliveries)
      .where(
        eq(
          billingEmailVerificationDeliveries.checkoutSessionId,
          input.checkoutSessionId,
        ),
      )
      .limit(1);

    if (existing?.sentAt) return "already_sent";
    if (
      existing &&
      (existing.stackUserId !== input.stackUserId || existing.email !== input.email)
    ) {
      throw new Error("Purchase magic-link ownership changed before delivery");
    }
    if (existing?.deliveryStartedAt) {
      // Do not reclaim an ambiguous request merely because the two-minute
      // attempt lease expired. The provider call may still be in flight, and
      // Stack does not accept a delivery idempotency key. The 23-hour window
      // matches Stack's practical magic-link delivery lifetime.
      if (
        claimedAt.getTime() - existing.deliveryStartedAt.getTime() >=
        AMBIGUOUS_RETRY_WINDOW_MS
      ) {
        return "delivery_abandoned";
      }
      return "delivery_in_progress";
    }
    if (
      existing?.attemptLeaseExpiresAt &&
      existing.attemptLeaseExpiresAt > claimedAt
    ) {
      return "delivery_in_progress";
    }

    const attemptLeaseExpiresAt = new Date(
      claimedAt.getTime() + ATTEMPT_LEASE_MS,
    );
    if (!existing) {
      await tx.insert(billingEmailVerificationDeliveries).values({
        checkoutSessionId: input.checkoutSessionId,
        stackUserId: input.stackUserId,
        email: input.email,
        deliveryStartedAt: claimedAt,
        attemptLeaseExpiresAt,
        updatedAt: claimedAt,
      });
    } else {
      await tx
        .update(billingEmailVerificationDeliveries)
        .set({
          deliveryStartedAt: existing.deliveryStartedAt ?? claimedAt,
          attemptLeaseExpiresAt,
          updatedAt: claimedAt,
        })
        .where(
          eq(
            billingEmailVerificationDeliveries.checkoutSessionId,
            input.checkoutSessionId,
          ),
        );
    }
    return "claimed";
  });
}

async function markDeliverySent(
  db: DeliveryDb,
  input: PurchaseMagicLinkDeliveryInput,
  sentAt: Date,
): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${deliveryLockKey(input.checkoutSessionId)}, 0))`,
    );
    await tx
      .update(billingEmailVerificationDeliveries)
      .set({
        sentAt,
        attemptLeaseExpiresAt: null,
        updatedAt: sentAt,
      })
      .where(
        eq(
          billingEmailVerificationDeliveries.checkoutSessionId,
          input.checkoutSessionId,
        ),
      );
  });
}

async function releaseDeliveryAttempt(
  db: DeliveryDb,
  input: PurchaseMagicLinkDeliveryInput,
  releasedAt: Date,
): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${deliveryLockKey(input.checkoutSessionId)}, 0))`,
    );
    await tx
      .update(billingEmailVerificationDeliveries)
      .set({
        deliveryStartedAt: null,
        attemptLeaseExpiresAt: null,
        updatedAt: releasedAt,
      })
      .where(
        eq(
          billingEmailVerificationDeliveries.checkoutSessionId,
          input.checkoutSessionId,
        ),
      );
  });
}

function deliveryLockKey(checkoutSessionId: string): string {
  return `billing-email-verification:${checkoutSessionId}`;
}
