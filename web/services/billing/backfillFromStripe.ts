import type Stripe from "stripe";
import { applySubscriptionUpdate } from "./purchase";
import { stripe } from "./stripe";

/**
 * Rebuild the Stripe mirror tables from Stripe itself.
 *
 * `reconcileStripeSubscriptions` repairs drift for subscriptions the database
 * already knows about. This walks every subscription in Stripe instead, so it
 * can rebuild an empty database after a migration or a lost mirror. Stripe
 * stays authoritative: each subscription goes through the same
 * `applySubscriptionUpdate` path as a signed webhook, which maps the customer
 * to a Stack user from the `stackUserId` metadata when no customer row
 * exists yet, upserts the customer and subscription rows, and re-syncs the
 * Pro plan metadata on the Stack user.
 */
export type StripeBackfillResult = {
  readonly listed: number;
  readonly cmux: number;
  readonly applied: number;
  readonly skipped: number;
  readonly failed: number;
  readonly failures: readonly { readonly id: string; readonly message: string }[];
};

export type StripeBackfillDependencies = {
  readonly list?: () => AsyncIterable<Stripe.Subscription>;
  readonly apply?: (subscription: Stripe.Subscription) => Promise<unknown>;
  readonly apply_mode?: "dry-run" | "apply";
  readonly log?: (line: string) => void;
};

export function isCmuxSubscription(subscription: Stripe.Subscription): boolean {
  return subscription.metadata?.app === "cmux";
}

export async function backfillSubscriptionsFromStripe(
  dependencies: StripeBackfillDependencies = {},
): Promise<StripeBackfillResult> {
  const list = dependencies.list ?? defaultList;
  const apply = dependencies.apply ?? ((subscription) => applySubscriptionUpdate(subscription));
  const mode = dependencies.apply_mode ?? "dry-run";
  const log = dependencies.log ?? (() => undefined);

  let listed = 0;
  let cmux = 0;
  let applied = 0;
  let skipped = 0;
  const failures: { id: string; message: string }[] = [];

  for await (const subscription of list()) {
    listed += 1;
    if (!isCmuxSubscription(subscription)) continue;
    cmux += 1;
    const owner = subscription.metadata?.stackTeamId
      ? `team ${subscription.metadata.stackTeamId}`
      : `user ${subscription.metadata?.stackUserId ?? "<no stackUserId>"}`;
    if (mode === "dry-run") {
      log(`would apply ${subscription.id} status=${subscription.status} ${owner}`);
      continue;
    }
    try {
      const result = await apply(subscription);
      if (result && typeof result === "object" && "skipped" in result) {
        skipped += 1;
        log(`skipped ${subscription.id} status=${subscription.status} ${owner}`);
      } else {
        applied += 1;
        log(`applied ${subscription.id} status=${subscription.status} ${owner}`);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      failures.push({ id: subscription.id, message });
      log(`failed ${subscription.id}: ${message}`);
    }
  }

  return { listed, cmux, applied, skipped, failed: failures.length, failures };
}

async function* defaultList(): AsyncIterable<Stripe.Subscription> {
  // `status: "all"` includes canceled subscriptions, whose rows matter for
  // grace periods and for founders lockout history.
  for await (const subscription of stripe().subscriptions.list({
    status: "all",
    limit: 100,
  })) {
    yield subscription;
  }
}
