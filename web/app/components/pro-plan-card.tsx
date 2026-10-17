"use client";

import { useId, useState, type ReactNode } from "react";
import { posthog } from "../lib/posthog-client";
import {
  MAX_PRICING_USD,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  type PlanPrice,
  type BillingInterval,
} from "../../services/billing/plans";
import { ProCtaLink } from "../[locale]/components/pro-cta-link";
import { usePricingIntervalContext } from "./pricing-checkout";

export type ProAnnualLabels = {
  billingPeriod: string;
  yearly: string;
  monthly: string;
  perMonth: string;
  monthlyPeriod?: string;
  annualPeriod?: string;
};

type CardPricing = {
  month: PlanPrice;
  year?: PlanPrice;
};

/**
 * The recurring pricing card. Pro and Team are sold yearly, so
 * the card owns the billing period: its price, checkout link, and CTA
 * analytics always agree.
 * When a page supplies a shared billing-period selector, the card follows it;
 * standalone cards retain their local period toggle.
 */
export function ProPlanCard({
  name,
  badge,
  labels,
  checkoutHrefs,
  location = "pricing_page",
  surface,
  requiresSignIn,
  ctaLabel,
  action,
  monthlyOnly = false,
  initialInterval = "year",
  plan = "pro",
  pricing,
  children,
}: {
  name: string;
  badge?: ReactNode;
  labels: ProAnnualLabels;
  /** One checkout link per billing period, built by the page. */
  checkoutHrefs: Partial<Record<BillingInterval, string>>;
  location?: string;
  surface: string;
  requiresSignIn: boolean;
  ctaLabel: string;
  /** A non-checkout action (manage billing, App Store); hides the period toggle. */
  action?: ReactNode;
  /**
   * The account's checkout goes to the Stripe portal plan switch, which
   * offers monthly prices only (a Go subscriber upgrading), so no toggle.
   */
  monthlyOnly?: boolean;
  /** A link back from checkout (`?interval=month`) keeps the buyer's period. */
  initialInterval?: BillingInterval;
  plan?: "pro" | "max" | "team";
  pricing?: Readonly<CardPricing>;
  children: ReactNode;
}) {
  const planPricing = cardPricing(plan, pricing);
  const hasAnnualPrice = Boolean(planPricing.year);
  const sharedInterval = usePricingIntervalContext();
  const [chosen, setInterval] = useState<BillingInterval>(initialInterval);
  const interval = selectedInterval({ monthlyOnly, hasAnnualPrice, sharedInterval, chosen });
  const radioName = useId();
  const select = (next: BillingInterval) => {
    const nextPrice = planPricing[next];
    if (!nextPrice) return;
    sharedInterval?.setInterval(next);
    setInterval(next);
    posthog.capture("cmuxterm_pricing_interval_selected", {
      surface,
      plan,
      interval: next,
      billed_amount_usd: nextPrice.billedAmount,
      discount_percent: nextPrice.discountPercent,
    });
  };
  // A subscriber sees their own plan, whose period the card does not know,
  // so the monthly price stays the reference there.
  const price = planPricing[action ? "month" : interval] ?? planPricing.month;

  return (
    <div className="relative flex h-full min-w-0 flex-col border border-border p-6">
      {badge ? <div className="absolute right-6 top-6">{badge}</div> : null}
      <CardHeader
        name={name}
        labels={labels}
        action={action}
        monthlyOnly={monthlyOnly}
        hasAnnualPrice={hasAnnualPrice}
        sharedInterval={sharedInterval}
        radioName={radioName}
        interval={interval}
        select={select}
      />
      <div className="mt-3">
        <div className="flex items-baseline gap-1.5">
          <span className="text-3xl font-medium tabular-nums tracking-tight">
            {`$${price.monthlyEquivalent}`}
          </span>
          <span className="max-w-44 text-sm leading-snug text-muted">
            {pricePeriodLabel(action ? "month" : interval, labels)}
          </span>
        </div>
      </div>
      <div className="mt-3">
        {action ?? (
          <ProCtaLink
            checkoutHref={checkoutHrefs[interval] ?? checkoutHrefs.month}
            requiresSignIn={requiresSignIn}
            interval={interval}
            location={location}
            plan={plan}
          >
            {ctaLabel}
          </ProCtaLink>
        )}
      </div>
      {children}
    </div>
  );
}

function cardPricing(
  plan: "pro" | "max" | "team",
  pricing: Readonly<CardPricing> | undefined,
): Readonly<CardPricing> {
  if (pricing) return pricing;
  if (plan === "max") return MAX_PRICING_USD;
  if (plan === "team") return TEAM_PRICING_USD;
  return PRO_PRICING_USD;
}

function selectedInterval({
  monthlyOnly,
  hasAnnualPrice,
  sharedInterval,
  chosen,
}: {
  monthlyOnly: boolean;
  hasAnnualPrice: boolean;
  sharedInterval: ReturnType<typeof usePricingIntervalContext>;
  chosen: BillingInterval;
}): BillingInterval {
  if (monthlyOnly || !hasAnnualPrice) return "month";
  return sharedInterval?.interval ?? chosen;
}

function CardHeader({
  name,
  labels,
  action,
  monthlyOnly,
  hasAnnualPrice,
  sharedInterval,
  radioName,
  interval,
  select,
}: {
  name: string;
  labels: ProAnnualLabels;
  action?: ReactNode;
  monthlyOnly: boolean;
  hasAnnualPrice: boolean;
  sharedInterval: ReturnType<typeof usePricingIntervalContext>;
  radioName: string;
  interval: BillingInterval;
  select: (interval: BillingInterval) => void;
}) {
  if (action || monthlyOnly || !hasAnnualPrice || sharedInterval) {
    return <h2 className="pr-28 text-sm font-medium tracking-tight">{name}</h2>;
  }
  return (
    <div className="flex items-center justify-between gap-3">
      <h2 className="text-sm font-medium tracking-tight">{name}</h2>
      <BillingPeriodControls
        labels={labels}
        radioName={radioName}
        interval={interval}
        select={select}
      />
    </div>
  );
}

function BillingPeriodControls({
  labels,
  radioName,
  interval,
  select,
}: {
  labels: ProAnnualLabels;
  radioName: string;
  interval: BillingInterval;
  select: (interval: BillingInterval) => void;
}) {
  return (
    <fieldset className="flex items-center gap-1.5 text-sm">
      <legend className="sr-only">{labels.billingPeriod}</legend>
      {["year", "month"].map((option, index) => {
        const nextInterval = option as BillingInterval;
        return (
          <span key={option} className="flex items-center gap-1.5">
            {index > 0 ? (
              <span aria-hidden className="text-muted">
                ·
              </span>
            ) : null}
            <label className="cursor-pointer">
              <input
                type="radio"
                name={radioName}
                value={nextInterval}
                checked={interval === nextInterval}
                onChange={() => select(nextInterval)}
                className="peer sr-only"
              />
              <span className="transition-colors text-muted hover:text-foreground peer-checked:font-medium peer-checked:text-foreground peer-focus-visible:underline peer-focus-visible:underline-offset-4">
                {nextInterval === "year" ? labels.yearly : labels.monthly}
              </span>
            </label>
          </span>
        );
      })}
    </fieldset>
  );
}

function pricePeriodLabel(interval: BillingInterval, labels: ProAnnualLabels) {
  return interval === "year"
    ? labels.annualPeriod ?? labels.perMonth
    : labels.monthlyPeriod ?? labels.perMonth;
}
