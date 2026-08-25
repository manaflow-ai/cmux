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
    billedAmount: 30,
    monthlyEquivalent: 30,
    discountPercent: 0,
    lookupKey: "cmux-pro-monthly",
  },
  year: {
    billedAmount: 288,
    monthlyEquivalent: 24,
    discountPercent: 20,
    lookupKey: "cmux-pro-yearly-288",
  },
} as const satisfies PlanPricing;

export const TEAM_PRICING_USD = {
  month: {
    billedAmount: 35,
    monthlyEquivalent: 35,
    discountPercent: 0,
    lookupKey: "cmux-team-monthly",
  },
  year: {
    billedAmount: 336,
    monthlyEquivalent: 28,
    discountPercent: 20,
    lookupKey: "cmux-team-yearly-336",
  },
} as const satisfies PlanPricing;

export const LEGACY_PRO_YEARLY_LOOKUP_KEY = "cmux-pro-yearly";

export function billingInterval(value: string | null | undefined): BillingInterval {
  return value === "year" ? "year" : "month";
}

export const proBillingInterval = billingInterval;
