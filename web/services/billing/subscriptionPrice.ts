import { planItem } from "./subscriptionItems";

/**
 * What a stored Stripe subscription actually charges, read from the plan
 * item's Price (planItem: never a metered usage item) in the raw Stripe payload. Amounts are immutable per Price, so
 * grandfathered rows render their own figure without a copy table.
 */
export type SubscriptionPrice = {
  /** Whole-currency amount per unit per interval (USD only). */
  readonly amountUsd: number;
  readonly interval: "month" | "year";
};

export function subscriptionPriceFromRaw(raw: unknown): SubscriptionPrice | null {
  const price = stripePrice(raw);
  const unitAmount = price?.unit_amount;
  const interval = recurringInterval(price);
  // unit_amount is in the currency's minor unit; only USD is formatted. A
  // non-USD row (operator-managed only) shows no figure rather than a false one.
  if (
    price?.currency !== "usd" ||
    typeof unitAmount !== "number" ||
    !Number.isFinite(unitAmount) ||
    !interval
  ) {
    return null;
  }
  return { amountUsd: unitAmount / 100, interval };
}

export function formatUsd(amount: number): string {
  return Number.isInteger(amount) ? String(amount) : amount.toFixed(2);
}

function stripePrice(raw: unknown): Record<string, unknown> | null {
  const item = raw && typeof raw === "object" ? planItem(raw as Parameters<typeof planItem>[0]) : undefined;
  const price = item && typeof item === "object" && "price" in item
    ? (item as { price?: unknown }).price
    : null;
  return price && typeof price === "object" ? (price as Record<string, unknown>) : null;
}

function recurringInterval(price: Record<string, unknown> | null): "month" | "year" | null {
  const recurring = price?.recurring;
  const interval = recurring && typeof recurring === "object"
    ? (recurring as { interval?: unknown }).interval
    : null;
  return interval === "month" || interval === "year" ? interval : null;
}
