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

export const PRO_PRICING_USD = {
  month: {
    billedAmount: 45,
    monthlyEquivalent: 45,
    discountPercent: 0,
    lookupKey: "cmux-pro-monthly-45",
  },
  year: {
    billedAmount: 432,
    monthlyEquivalent: 36,
    discountPercent: 20,
    lookupKey: "cmux-pro-yearly-432",
  },
} as const satisfies PlanPricing;

export const TEAM_PRICING_USD = {
  month: {
    billedAmount: 50,
    monthlyEquivalent: 50,
    discountPercent: 0,
    lookupKey: "cmux-team-monthly-50",
  },
  year: {
    billedAmount: 480,
    monthlyEquivalent: 40,
    discountPercent: 20,
    lookupKey: "cmux-team-yearly-480",
  },
} as const satisfies PlanPricing;

// Grandfathered price lookup keys from the pre-2026-09 catalog ($30/$288
// Pro, $35/$336 Team). Plan identity resolves from the Stripe product's
// metadata, not the price, so subscriptions on these prices keep their
// entitlements; the keys stay listed for provisioning and audits.
export const LEGACY_PRO_YEARLY_LOOKUP_KEY = "cmux-pro-yearly";
export const LEGACY_PRO_MONTHLY_LOOKUP_KEY = "cmux-pro-monthly";
export const LEGACY_PRO_YEARLY_288_LOOKUP_KEY = "cmux-pro-yearly-288";
export const LEGACY_TEAM_MONTHLY_LOOKUP_KEY = "cmux-team-monthly";
export const LEGACY_TEAM_YEARLY_336_LOOKUP_KEY = "cmux-team-yearly-336";

export function billingInterval(value: string | null | undefined): BillingInterval {
  return value === "year" ? "year" : "month";
}

export const proBillingInterval = billingInterval;
