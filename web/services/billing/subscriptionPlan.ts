import type Stripe from "stripe";
import { MAX_PRICING_USD, TEAM_MAX_PRICING_USD } from "./plans";
import { planItem } from "./subscriptionItems";

export function personalPlanIdForSubscription(
  subscription: Pick<Stripe.Subscription, "items" | "metadata">,
  sessionMetadata?: Stripe.Metadata | null,
): "go" | "pro" | "max" | null {
  // Verified legacy Founder purchases carry this explicit entitlement marker.
  if (subscription.metadata?.founders_edition === "true") return "pro";
  const lookupKey = planItem(subscription)?.price?.lookup_key;
  if (typeof lookupKey === "string") {
    if (lookupKey === "cmux-go-monthly-10" || lookupKey.startsWith("cmux-go-")) return "go";
    if (lookupKey === MAX_PRICING_USD.month.lookupKey || lookupKey.startsWith("cmux-max-")) {
      return "max";
    }
    if (lookupKey.startsWith("cmux-pro-")) return "pro";
    if (lookupKey.trim()) return null;
  }
  const metadataPlan = subscription.metadata?.plan ?? sessionMetadata?.plan;
  return (metadataPlan === "go" || metadataPlan === "pro" || metadataPlan === "max") ? metadataPlan : null;
}

/** Unknown billing data must never be persisted as a paid entitlement. */
export function requirePersonalPlanIdForSubscription(
  subscription: Pick<Stripe.Subscription, "items" | "metadata">,
  sessionMetadata?: Stripe.Metadata | null,
): "go" | "pro" | "max" {
  const plan = personalPlanIdForSubscription(subscription, sessionMetadata);
  if (!plan) throw new Error("Unrecognized personal subscription plan; reconcile its Stripe price before granting access");
  return plan;
}

/**
 * The team plan a team-scoped subscription sells, read from its Price so an
 * in-place Team <-> Team Max switch (a price swap on the same subscription)
 * re-labels the row on the next webhook. Checkout metadata is the fallback
 * for a payload without a lookup key; anything else stays Team.
 */
export function teamPlanIdForSubscription(
  subscription: Pick<Stripe.Subscription, "items" | "metadata">,
): "team" | "team_max" {
  const lookupKey = planItem(subscription)?.price?.lookup_key;
  if (typeof lookupKey === "string" && lookupKey.trim()) {
    return lookupKey === TEAM_MAX_PRICING_USD.month.lookupKey || lookupKey.startsWith("cmux-team-max-")
      ? "team_max"
      : "team";
  }
  return subscription.metadata?.plan === "team_max" ? "team_max" : "team";
}
