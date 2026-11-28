import type Stripe from "stripe";

import type { BillingInterval } from "./plans";

export type PlanPrice = { readonly billedAmount: number; readonly lookupKey: string };

/** The Stripe Price fields the guard inspects; `product` must be expanded. */
export type GuardedPrice = Pick<Stripe.Price, "id" | "active" | "currency" | "unit_amount" | "recurring"> & {
  readonly product: string | Pick<Stripe.Product, "id" | "metadata"> | Pick<Stripe.DeletedProduct, "id" | "deleted">;
};

/**
 * Refuses a Stripe Price that does not charge what the pricing page says.
 * Used for env price-id overrides, whose names only claim an amount; a stale
 * or miscopied id (say, a grandfathered $30 Price behind
 * STRIPE_PRO_MONTHLY_50_PRICE_ID) fails here instead of silently selling the
 * old price. Kept dependency-free so it can be tested without a Stripe client.
 */
export function assertPriceMatchesPlan(
  price: GuardedPrice,
  plan: PlanPrice,
  interval: BillingInterval,
  source: string,
  planId: string,
): void {
  const expectedAmount = plan.billedAmount * 100;
  const problems: string[] = [];
  if (!price.active) problems.push("inactive");
  // The catalog script stamps every cmux product with metadata.app/plan, so
  // an override must belong to this plan's product, not merely cost the same.
  const product = price.product;
  if (typeof product === "string") {
    problems.push("product not expanded");
  } else if ("deleted" in product && product.deleted) {
    problems.push(`product ${product.id} deleted`);
  } else {
    const metadata = (product as Pick<Stripe.Product, "metadata">).metadata ?? {};
    if (metadata.app !== "cmux" || metadata.plan !== planId) {
      problems.push(`product ${product.id} is not the cmux ${planId} product`);
    }
  }
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
