export type BillingInterval = "month" | "year";
export type ProBillingInterval = BillingInterval;

type PlanPricing = Record<
  BillingInterval,
  {
    billedAmount: number;
    monthlyEquivalent: number;
    discountPercent: number;
    lookupKey: string;
  }
>;

// Stripe Price amounts are immutable, so every price change mints a new
// lookup key and leaves the old Price active for the subscriptions already on
// it (see LEGACY_PRICE_LOOKUP_KEYS). The lookup key carries the amount so a
// stale env override or catalog row can never masquerade as the current price.
export const PRO_PRICING_USD = {
  month: {
    billedAmount: 50,
    monthlyEquivalent: 50,
    discountPercent: 0,
    lookupKey: "cmux-pro-monthly-50",
  },
  year: {
    billedAmount: 480,
    monthlyEquivalent: 40,
    discountPercent: 20,
    lookupKey: "cmux-pro-yearly-480",
  },
} as const satisfies PlanPricing;

export const TEAM_PRICING_USD = {
  month: {
    billedAmount: 60,
    monthlyEquivalent: 60,
    discountPercent: 0,
    lookupKey: "cmux-team-monthly-60",
  },
  year: {
    billedAmount: 576,
    monthlyEquivalent: 48,
    discountPercent: 20,
    lookupKey: "cmux-team-yearly-576",
  },
} as const satisfies PlanPricing;

/**
 * Lookup keys that no new checkout may use. Each stays active in Stripe for
 * the subscriptions grandfathered on it; the dashboard prices those rows from
 * the subscription's own Stripe amount, never from these keys.
 */
export const LEGACY_PRICE_LOOKUP_KEYS = [
  "cmux-pro-monthly", // $30/mo
  "cmux-pro-yearly", // $240/yr
  "cmux-pro-yearly-288", // $288/yr
  "cmux-team-monthly", // $35/user/mo
  "cmux-team-yearly-336", // $336/user/yr
] as const;

export function billingInterval(value: string | null | undefined): BillingInterval {
  return value === "year" ? "year" : "month";
}

export const proBillingInterval = billingInterval;
