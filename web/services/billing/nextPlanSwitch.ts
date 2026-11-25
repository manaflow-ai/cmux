// cmux NEXT plan upgrades: a subscriber on a lower NEXT plan (Plus, or Pro)
// moves to a higher one in the Stripe Billing Portal's subscription-update
// flow, on the same subscription (one NEXT subscription per person; checkout
// never sells a second). The default portal configuration allows no price
// switch, so the flow names a NEXT switch configuration that lists the NEXT
// Prices. The server finds it by metadata, or creates it on first use from the
// configured Prices: nothing has to be provisioned by hand. A change of the
// configured Prices makes a new configuration (its `prices` metadata names them).

import { NEXT_PLAN_IDS, nextPlanPriceId, type NextPlanId } from "./nextPlans";
import { resolveNextPlanPrice, stripe } from "./stripe";

export const NEXT_PLAN_SWITCH_PORTAL_METADATA = { app: "cmux", purpose: "next_plan_switch" } as const;

const resolvedConfigurations = new Map<string, string>();

/** Tests only: forget the configurations found or made, so each test starts from Stripe. */
export function resetNextPlanSwitchCacheForTests(): void {
  resolvedConfigurations.clear();
}

/** The NEXT plans for sale (their Price is configured), lowest first. */
function nextPlansForSale(): NextPlanId[] {
  return NEXT_PLAN_IDS.filter((plan) => nextPlanPriceId(plan) !== null);
}

/**
 * The portal configuration that switches between the NEXT Prices for sale.
 * Each Price is checked as checkout checks it (amount, interval, Product
 * metadata) before it is offered.
 */
export async function resolveNextPlanSwitchPortalConfiguration(): Promise<string> {
  const plans = nextPlansForSale();
  const prices = await Promise.all(plans.map((plan) => resolveNextPlanPrice(plan)));
  const key = prices.join(",");
  const cached = resolvedConfigurations.get(key);
  if (cached) return cached;
  const client = stripe();
  const configurations = await client.billingPortal.configurations.list({ active: true, limit: 100 });
  const found = configurations.data.find((configuration) =>
    configuration.metadata?.app === NEXT_PLAN_SWITCH_PORTAL_METADATA.app &&
    configuration.metadata?.purpose === NEXT_PLAN_SWITCH_PORTAL_METADATA.purpose &&
    configuration.metadata?.prices === key,
  );
  if (found) {
    resolvedConfigurations.set(key, found.id);
    return found.id;
  }
  const products = await Promise.all(prices.map(async (price) => {
    const retrieved = await client.prices.retrieve(price);
    return typeof retrieved.product === "string" ? retrieved.product : retrieved.product.id;
  }));
  const created = await client.billingPortal.configurations.create({
    features: {
      subscription_update: {
        enabled: true,
        default_allowed_updates: ["price"],
        proration_behavior: "always_invoice",
        products: prices.map((price, index) => ({
          product: products[index]!,
          prices: [price],
          adjustable_quantity: { enabled: false },
        })),
      },
      subscription_cancel: { enabled: true, mode: "at_period_end" },
      invoice_history: { enabled: true },
      payment_method_update: { enabled: true },
    },
    metadata: { ...NEXT_PLAN_SWITCH_PORTAL_METADATA, prices: key },
  });
  resolvedConfigurations.set(key, created.id);
  return created.id;
}

/** A Billing Portal session that opens the plan switch on the subscriber's NEXT subscription. */
export async function nextPlanSwitchPortalSession(input: {
  customerId: string;
  subscriptionId: string;
  origin: string;
}): Promise<{ url: string | null }> {
  return await stripe().billingPortal.sessions.create({
    customer: input.customerId,
    return_url: new URL("/dashboard/billing", input.origin).toString(),
    configuration: await resolveNextPlanSwitchPortalConfiguration(),
    flow_data: { type: "subscription_update", subscription_update: { subscription: input.subscriptionId } },
  });
}
