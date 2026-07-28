import Stripe from "stripe";

import { env } from "../../app/env";

export type ProBillingInterval = "month" | "year";

const PRO_PRICE_LOOKUP_KEYS: Record<ProBillingInterval, string> = {
  month: "cmux-pro-monthly",
  year: "cmux-pro-yearly",
};
const TEAM_PRICE_LOOKUP_KEY = "cmux-team-monthly";

let stripeClient: Stripe | null = null;
const resolvedPriceIds = new Map<ProBillingInterval, string>();
let resolvedTeamPriceId: string | null = null;

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

export async function resolveProPrice(interval: ProBillingInterval): Promise<string> {
  const overridden = interval === "month"
    ? env.STRIPE_PRO_MONTHLY_PRICE_ID
    : env.STRIPE_PRO_YEARLY_PRICE_ID;
  if (overridden) return overridden;

  const cached = resolvedPriceIds.get(interval);
  if (cached) return cached;

  const lookupKey = PRO_PRICE_LOOKUP_KEYS[interval];
  const prices = await stripe().prices.list({
    active: true,
    lookup_keys: [lookupKey],
    limit: 1,
  });
  const priceId = prices.data[0]?.id;
  if (!priceId) {
    throw new Error(`Stripe price lookup key not found: ${lookupKey}`);
  }
  resolvedPriceIds.set(interval, priceId);
  return priceId;
}

export async function resolveTeamPrice(): Promise<string> {
  if (env.STRIPE_TEAM_MONTHLY_PRICE_ID) return env.STRIPE_TEAM_MONTHLY_PRICE_ID;
  if (resolvedTeamPriceId) return resolvedTeamPriceId;

  const prices = await stripe().prices.list({
    active: true,
    lookup_keys: [TEAM_PRICE_LOOKUP_KEY],
    limit: 1,
  });
  const priceId = prices.data[0]?.id;
  if (!priceId) {
    throw new Error(`Stripe price lookup key not found: ${TEAM_PRICE_LOOKUP_KEY}`);
  }
  resolvedTeamPriceId = priceId;
  return priceId;
}
