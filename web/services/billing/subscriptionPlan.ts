import type Stripe from "stripe";
import { MAX_PRICING_USD } from "./plans";

export function personalPlanIdForSubscription(
  subscription: Pick<Stripe.Subscription, "items" | "metadata">,
  sessionMetadata?: Stripe.Metadata | null,
): "go" | "pro" | "max" {
  const lookupKey = subscription.items?.data?.[0]?.price?.lookup_key;
  if (typeof lookupKey === "string") {
    if (lookupKey === "cmux-go-monthly-10" || lookupKey.startsWith("cmux-go-")) return "go";
    if (lookupKey === MAX_PRICING_USD.month.lookupKey || lookupKey.startsWith("cmux-max-")) {
      return "max";
    }
    if (lookupKey.startsWith("cmux-pro-")) return "pro";
  }
  const metadataPlan = subscription.metadata?.plan ?? sessionMetadata?.plan;
  return (metadataPlan === "go" || metadataPlan === "pro" || metadataPlan === "max") ? metadataPlan : "pro";
}
