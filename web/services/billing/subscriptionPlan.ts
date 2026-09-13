import type Stripe from "stripe";
import { MAX_PRICING_USD } from "./plans";

export function personalPlanIdForSubscription(
  subscription: Pick<Stripe.Subscription, "items" | "metadata">,
  sessionMetadata?: Stripe.Metadata | null,
): "go" | "pro" | "max" | null {
  // Verified legacy Founder purchases carry this explicit entitlement marker.
  if (subscription.metadata?.founders_edition === "true") return "pro";
  const lookupKey = subscription.items?.data?.[0]?.price?.lookup_key;
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
