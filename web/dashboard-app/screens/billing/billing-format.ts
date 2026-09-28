import { formatUsd, type SubscriptionPrice } from "@/services/billing/subscriptionPrice";

/** A billing period end as the locale's medium date, or null when absent. */
export function formatBillingDate(iso: string | null, locale: string): string | null {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium" }).format(date);
}

type PriceTranslator = (key: string, values: Record<string, string>) => string;

/**
 * What a subscription charges, read from its Stripe price. Amounts are
 * immutable per Price, so grandfathered rows render their own figure.
 */
export function personalPriceCopy(
  t: PriceTranslator,
  price: SubscriptionPrice | null,
  plan: "go" | "pro" | "max",
): string | null {
  if (!price) return null;
  if (price.interval === "month") {
    return t(`${plan}.monthlyPrice`, { amount: formatUsd(price.amountUsd) });
  }
  return t(plan === "pro" ? "pro.annualPrice" : `${plan}.monthlyPrice`, {
    monthly: formatUsd(price.amountUsd / 12),
  });
}

export function teamPriceCopy(t: PriceTranslator, price: SubscriptionPrice | null): string | null {
  if (!price) return null;
  return price.interval === "month"
    ? t("team.price", { amount: formatUsd(price.amountUsd) })
    : t("team.annualPrice", { monthly: formatUsd(price.amountUsd / 12) });
}
