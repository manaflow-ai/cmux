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
      // committed. The lease prevents a concurrent webhook from sending twice.
      await deliver();
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
    if (
      existing?.deliveryStartedAt &&
      claimedAt.getTime() - existing.deliveryStartedAt.getTime() >=
        AMBIGUOUS_RETRY_WINDOW_MS
    ) {
      return "delivery_abandoned";
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

function deliveryLockKey(checkoutSessionId: string): string {
  return `billing-email-verification:${checkoutSessionId}`;
}
