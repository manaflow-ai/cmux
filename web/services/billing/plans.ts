export type BillingInterval = "month" | "year";
export type ProBillingInterval = BillingInterval;

export type PlanPrice = {
  billedAmount: number;
  monthlyEquivalent: number;
  discountPercent: number;
  lookupKey: string;
};

/** A plan sold on one billing interval only; `year` is deliberately absent. */
type MonthlyOnlyPlanPricing = Record<"month", PlanPrice>;

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
} as const satisfies MonthlyOnlyPlanPricing;

/** Entry Cloud plan, billed monthly with a small capped VM allowance. */
export const GO_PRICING_USD = {
  month: {
    billedAmount: 10,
    monthlyEquivalent: 10,
    discountPercent: 0,
    lookupKey: "cmux-go-monthly-10",
  },
} as const satisfies MonthlyOnlyPlanPricing;

export const TEAM_PRICING_USD = {
  month: {
    billedAmount: 60,
    monthlyEquivalent: 60,
    discountPercent: 0,
    lookupKey: "cmux-team-monthly-60",
  },
} as const satisfies MonthlyOnlyPlanPricing;

/**
 * Max is a personal plan above Pro: the same allowance, plus the 32 GB and
 * 64 GB machine sizes Pro cannot start. It is monthly only, so there is no
 * annual price and no interval selector on its card.
 */
export const MAX_PRICING_USD = {
  month: {
    billedAmount: 200,
    monthlyEquivalent: 200,
    discountPercent: 0,
    lookupKey: "cmux-max-monthly-200",
  },
} as const satisfies MonthlyOnlyPlanPricing;

/** Every new subscription is monthly. Historical annual subscriptions remain valid. */
export const CHECKOUT_BILLING_INTERVAL = "month" as const;
export const MAX_BILLING_INTERVALS: readonly BillingInterval[] = ["month"];
export const GO_BILLING_INTERVALS: readonly BillingInterval[] = ["month"];

/**
 * Lookup keys that no new checkout may use. Each stays active in Stripe for
 * the subscriptions grandfathered on it; the dashboard prices those rows from
 * the subscription's own Stripe amount, never from these keys.
 */
export const LEGACY_PRICE_LOOKUP_KEYS = [
  "cmux-pro-monthly", // $30/mo
  "cmux-pro-yearly", // $240/yr
  "cmux-pro-yearly-288", // $288/yr
  "cmux-pro-yearly-480", // $480/yr; existing subscriptions only
  "cmux-team-monthly", // $35/user/mo
  "cmux-team-yearly-336", // $336/user/yr
  "cmux-team-yearly-576", // $576/user/yr; existing subscriptions only
] as const;

export function billingInterval(value: string | null | undefined): BillingInterval {
  return value === "year" ? "year" : "month";
}

export const proBillingInterval = billingInterval;
