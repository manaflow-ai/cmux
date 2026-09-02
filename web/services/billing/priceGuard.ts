import type Stripe from "stripe";

import type { BillingInterval } from "./plans";

export type PlanPrice = { readonly billedAmount: number; readonly lookupKey: string };

/**
 * Refuses a Stripe Price that does not charge what the pricing page says.
 * Used for env price-id overrides, whose names only claim an amount; a stale
 * or miscopied id (say, a grandfathered $30 Price behind
 * STRIPE_PRO_MONTHLY_50_PRICE_ID) fails here instead of silently selling the
 * old price. Kept dependency-free so it can be tested without a Stripe client.
 */
export function assertPriceMatchesPlan(
  price: Pick<Stripe.Price, "id" | "active" | "currency" | "unit_amount" | "recurring">,
  plan: PlanPrice,
  interval: BillingInterval,
  source: string,
): void {
  const expectedAmount = plan.billedAmount * 100;
  const problems: string[] = [];
  if (!price.active) problems.push("inactive");
  if (price.currency !== "usd") problems.push(`currency ${price.currency}`);
  if (price.unit_amount !== expectedAmount) {
    problems.push(`unit_amount ${price.unit_amount ?? "null"} (expected ${expectedAmount})`);
  }
  if (price.recurring?.interval !== interval || (price.recurring.interval_count ?? 1) !== 1) {
    problems.push(`interval ${price.recurring?.interval_count ?? 1}×${price.recurring?.interval ?? "none"} (expected 1×${interval})`);
  }
  if (problems.length > 0) {
    throw new Error(
      `Stripe price override ${source} (${price.id}) does not match ${plan.lookupKey}: ${problems.join(", ")}`,
    );
  }
}
