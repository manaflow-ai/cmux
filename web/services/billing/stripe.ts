import Stripe from "stripe";

import { env } from "../../app/env";
import {
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  type BillingInterval,
} from "./plans";

export type { BillingInterval, ProBillingInterval } from "./plans";

let stripeClient: Stripe | null = null;
const resolvedProPriceIds = new Map<BillingInterval, string>();
const resolvedTeamPriceIds = new Map<BillingInterval, string>();

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
    ? env.STRIPE_PRO_MONTHLY_PRICE_ID
    : env.STRIPE_PRO_YEARLY_288_PRICE_ID;
  if (overridden) return overridden;

  const cached = resolvedProPriceIds.get(interval);
  if (cached) return cached;

  const lookupKey = PRO_PRICING_USD[interval].lookupKey;
  const prices = await stripe().prices.list({
    active: true,
    lookup_keys: [lookupKey],
    limit: 1,
  });
  const priceId = prices.data[0]?.id;
  if (!priceId) {
    throw new Error(`Stripe price lookup key not found: ${lookupKey}`);
  }
  resolvedProPriceIds.set(interval, priceId);
  return priceId;
}

export async function resolveTeamPrice(interval: BillingInterval): Promise<string> {
  const overridden = interval === "month"
    ? env.STRIPE_TEAM_MONTHLY_PRICE_ID
    : env.STRIPE_TEAM_YEARLY_PRICE_ID;
  if (overridden) return overridden;

  const cached = resolvedTeamPriceIds.get(interval);
  if (cached) return cached;

  const lookupKey = TEAM_PRICING_USD[interval].lookupKey;
  const prices = await stripe().prices.list({
    active: true,
    lookup_keys: [lookupKey],
    limit: 1,
  });
  const priceId = prices.data[0]?.id;
  if (!priceId) {
    throw new Error(`Stripe price lookup key not found: ${lookupKey}`);
  }
  resolvedTeamPriceIds.set(interval, priceId);
  return priceId;
}
