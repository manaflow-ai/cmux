import Stripe from "stripe";

import { env } from "../../app/env";
import {
  MAX_PRICING_USD,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  type BillingInterval,
} from "./plans";
import { assertPriceMatchesPlan, type PlanPrice } from "./priceGuard";

export type { BillingInterval, ProBillingInterval } from "./plans";

let stripeClient: Stripe | null = null;
const resolvedProPriceIds = new Map<BillingInterval, string>();
const resolvedTeamPriceIds = new Map<BillingInterval, string>();
const resolvedMaxPriceIds = new Map<BillingInterval, string>();

/**
 * Metadata the catalog script stamps on the Billing Portal configuration
 * that allows a personal subscription to switch between Pro and Max. The
 * default portal configuration deliberately allows quantity changes only,
 * so plan switches use this dedicated configuration by id.
 */
export const PERSONAL_PLAN_SWITCH_PORTAL_METADATA = {
  app: "cmux",
  purpose: "personal_plan_switch",
} as const;
let resolvedPersonalPlanSwitchConfigurationId: string | null = null;

/**
 * The id of the portal configuration provisioned for Pro <-> Max switches,
 * found by metadata like prices are found by lookup key. Throws when the
 * catalog script has not provisioned it in this Stripe mode.
 */
export async function resolvePersonalPlanSwitchPortalConfiguration(): Promise<string> {
  if (resolvedPersonalPlanSwitchConfigurationId) return resolvedPersonalPlanSwitchConfigurationId;
  const overridden = env.STRIPE_PERSONAL_PLAN_SWITCH_PORTAL_CONFIGURATION_ID;
  if (overridden) {
    resolvedPersonalPlanSwitchConfigurationId = overridden;
    return overridden;
  }
  const configurations = await stripe().billingPortal.configurations.list({
    active: true,
    limit: 100,
  });
  const found = configurations.data.find((configuration) =>
    configuration.metadata?.app === PERSONAL_PLAN_SWITCH_PORTAL_METADATA.app &&
    configuration.metadata?.purpose === PERSONAL_PLAN_SWITCH_PORTAL_METADATA.purpose,
  );
  if (!found) {
    throw new Error(
      "Stripe Billing Portal configuration for personal plan switches not found (run web/scripts/stripe/provision-catalog.sh)",
    );
  }
  resolvedPersonalPlanSwitchConfigurationId = found.id;
  return found.id;
}

export function isStripeBillingConfigured(): boolean {
  return Boolean(env.STRIPE_SECRET_KEY);
}

export function stripe(): Stripe {
  if (!env.STRIPE_SECRET_KEY) {
    throw new Error("Stripe billing is not configured");
  }
  stripeClient ??= new Stripe(env.STRIPE_SECRET_KEY, {
    apiVersion: "2026-06-24.dahlia",
  });
  return stripeClient;
}

export async function resolveProPrice(interval: BillingInterval): Promise<string> {
  const overridden = interval === "month"
    ? env.STRIPE_PRO_MONTHLY_50_PRICE_ID
    : env.STRIPE_PRO_YEARLY_480_PRICE_ID;
  return resolvePlanPrice(PRO_PRICING_USD[interval], interval, overridden, resolvedProPriceIds, "pro");
}

/** Max is sold monthly only; there is no yearly Price to resolve. */
export async function resolveMaxPrice(): Promise<string> {
  return resolvePlanPrice(
    MAX_PRICING_USD.month,
    "month",
    env.STRIPE_MAX_MONTHLY_200_PRICE_ID,
    resolvedMaxPriceIds,
    "max",
  );
}

export async function resolveTeamPrice(interval: BillingInterval): Promise<string> {
  const overridden = interval === "month"
    ? env.STRIPE_TEAM_MONTHLY_60_PRICE_ID
    : env.STRIPE_TEAM_YEARLY_576_PRICE_ID;
  return resolvePlanPrice(TEAM_PRICING_USD[interval], interval, overridden, resolvedTeamPriceIds, "team");
}

/**
 * The Stripe price id checkout will charge. A lookup-key resolution is
 * trusted (the catalog script pins the amount behind each key); an env
 * override is verified against the advertised amount, interval, and currency
 * on first use, so a stale or miscopied id can never sell a grandfathered
 * price under the current pricing page. Both results are cached per process.
 */
async function resolvePlanPrice(
  plan: PlanPrice,
  interval: BillingInterval,
  overridden: string | undefined,
  cache: Map<BillingInterval, string>,
  planId: "pro" | "max" | "team",
): Promise<string> {
  const cached = cache.get(interval);
  if (cached) return cached;

  let priceId: string;
  if (overridden) {
    const price = await stripe().prices.retrieve(overridden, { expand: ["product"] });
    assertPriceMatchesPlan(price, plan, interval, overridden, planId);
    priceId = price.id;
  } else {
    const prices = await stripe().prices.list({
      active: true,
      lookup_keys: [plan.lookupKey],
      limit: 1,
    });
    const found = prices.data[0]?.id;
    if (!found) {
      throw new Error(`Stripe price lookup key not found: ${plan.lookupKey}`);
    }
    priceId = found;
  }
  cache.set(interval, priceId);
  return priceId;
}
