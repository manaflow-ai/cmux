export type ProBillingInterval = "month" | "year";

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
} as const satisfies Record<
  ProBillingInterval,
  {
    billedAmount: number;
    monthlyEquivalent: number;
    discountPercent: number;
    lookupKey: string;
  }
>;

export const LEGACY_PRO_YEARLY_LOOKUP_KEY = "cmux-pro-yearly";

export function proBillingInterval(value: string | null | undefined): ProBillingInterval {
  return value === "year" ? "year" : "month";
}
