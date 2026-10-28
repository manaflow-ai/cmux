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
/** A plan sold monthly or yearly. */
type MonthlyOrYearlyPlanPricing = Record<BillingInterval, PlanPrice>;

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
  // Pro is sold yearly at 20% off: 12 months for the price of 9.6.
  year: {
    billedAmount: 480,
    monthlyEquivalent: 40,
    discountPercent: 20,
    lookupKey: "cmux-pro-yearly-480",
  },
} as const satisfies MonthlyOrYearlyPlanPricing;

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
 * Max is a personal plan above Pro: the same machine count, plus the 24, 32,
 * and 64 GB machine sizes (up to 32 vCPU) Pro cannot start. It follows the
 * same 20% annual discount as Pro.
 */
export const MAX_PRICING_USD = {
  month: {
    billedAmount: 200,
    monthlyEquivalent: 200,
    discountPercent: 0,
    lookupKey: "cmux-max-monthly-200",
  },
  year: {
    billedAmount: 1_920,
    monthlyEquivalent: 160,
    discountPercent: 20,
    lookupKey: "cmux-max-yearly-1920",
  },
} as const satisfies MonthlyOrYearlyPlanPricing;

/**
 * New checkouts default to monthly. Pro and Max also sell yearly Prices; Go
 * and Team stay monthly, and their historical annual subscriptions remain
 * valid.
 */
export const CHECKOUT_BILLING_INTERVAL = "month" as const;
/** New Pro customers can try Cloud for two weeks before the first charge. */
export const PRO_TRIAL_DAYS = 14;
export const PRO_BILLING_INTERVALS: readonly BillingInterval[] = ["month", "year"];
export const MAX_BILLING_INTERVALS: readonly BillingInterval[] = ["month", "year"];
export const GO_BILLING_INTERVALS: readonly BillingInterval[] = ["month"];

/**
 * The prices the hosted plan-switch portal lists, so the only subscriptions
 * it can switch (web/scripts/stripe/provision-catalog.sh provisions exactly
 * these). Every listed price is also a choice any subscriber in that portal
 * can pick. Yearly subscribers switch in the dashboard, which keeps their
 * interval, so Pro yearly is not listed: it would only let a monthly
 * subscriber move onto it. Neither a grandfathered price nor the
 * release-gated Go plan is listed; a subscription on one switches in the
 * dashboard instead, which prices any subscription.
 */
export const PORTAL_SWITCHABLE_LOOKUP_KEYS: readonly string[] = [
  PRO_PRICING_USD.month.lookupKey,
  MAX_PRICING_USD.month.lookupKey,
  MAX_PRICING_USD.year.lookupKey,
];

export function isPortalSwitchableLookupKey(lookupKey: string | null | undefined): boolean {
  return typeof lookupKey === "string" && PORTAL_SWITCHABLE_LOOKUP_KEYS.includes(lookupKey);
}

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
  "cmux-team-yearly-576", // $576/user/yr; existing subscriptions only
] as const;

export function billingInterval(value: string | null | undefined): BillingInterval {
  return value === "year" ? "year" : "month";
}

export const proBillingInterval = billingInterval;
