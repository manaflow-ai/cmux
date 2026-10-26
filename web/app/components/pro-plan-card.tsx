"use client";

import { useId, useState, type ReactNode } from "react";
import { posthog } from "../lib/posthog-client";
import {
  MAX_PRICING_USD,
  PRO_PRICING_USD,
  type PlanPrice,
  type BillingInterval,
} from "../../services/billing/plans";
import { formatUsd, type PlanCardSubscriptionPrice } from "../../services/billing/subscriptionPrice";
import { ProCtaLink } from "../[locale]/components/pro-cta-link";

export type ProAnnualLabels = {
  billingPeriod: string;
  yearly: string;
  monthly: string;
  perMonth: string;
  /** "Billed ${amount} yearly", with the literal `{amount}` placeholder. */
  billedYearlyTemplate: string;
  billedMonthly: string;
  /** Marks a subscriber's price that is below today's list price. */
  earlySupporterPrice: string;
  /** Labels a Founder's Edition owner's Pro price. */
  foundersEdition: string;
};

/**
 * The recurring personal-plan pricing card. Pro and Max are sold monthly or
 * yearly, so the card owns the billing period: its price, checkout link, and
 * CTA analytics always agree.
 * Monthly is the default and listed first, so checkout opens on the monthly
 * price; yearly shows its per-month equivalent. The period toggle sits in the
 * header row and the yearly note sits under the button, so the price block
 * and the button line up with the Free and Max cards in either period.
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
  initialInterval = "month",
  plan = "pro",
  pricing,
  currentPrice,
  currentPlan,
  children,
}: {
  name: string;
  badge?: ReactNode;
  labels: ProAnnualLabels;
  /** One checkout link per billing period, built by the page. */
  checkoutHrefs: Record<BillingInterval, string>;
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
  /** A link back from checkout (`?interval=year`) keeps the buyer's period. */
  initialInterval?: BillingInterval;
  plan?: "pro" | "max";
  pricing?: Readonly<Record<BillingInterval, PlanPrice>>;
  /**
   * What this subscriber's own Stripe subscription charges, set only on the
   * card of the plan in force. A grandfathered price (an early $30 Pro, or
   * Founder's Edition) shows here with today's list price struck through.
   */
  currentPrice?: PlanCardSubscriptionPrice;
  /** This card is the account's plan in force. */
  currentPlan?: boolean;
  children: ReactNode;
}) {
  const planPricing = pricing ?? (plan === "max" ? MAX_PRICING_USD : PRO_PRICING_USD);
  const [chosen, setInterval] = useState<BillingInterval>(initialInterval);
  const interval = monthlyOnly ? "month" : chosen;
  const radioName = useId();
  const select = (next: BillingInterval) => {
    setInterval(next);
    posthog.capture("cmuxterm_pricing_interval_selected", {
      surface,
      plan,
      interval: next,
      billed_amount_usd: planPricing[next].billedAmount,
      discount_percent: planPricing[next].discountPercent,
    });
  };
  // A subscriber with a known Stripe price sees what they pay. Otherwise a
  // subscriber's card does not know their period, so monthly stays the
  // reference there.
  const shown = cardPrice({
    pricing: planPricing,
    interval: action ? "month" : interval,
    currentPrice,
  });
  const billing = billingDetails({
    shown,
    currentPrice,
    labels,
    // The plan in force's card, without its own price, hides the toggle
    // and does not know the subscriber's period.
    periodKnown: !(currentPlan && action) || currentPrice !== undefined,
  });

  return (
    <div className="relative flex h-full min-w-0 flex-col border border-border p-6">
      {badge ? <div className="absolute right-6 top-6">{badge}</div> : null}
      {action || monthlyOnly ? (
        <h2 className="pr-28 text-sm font-medium tracking-tight">{name}</h2>
      ) : (
        <div className="flex items-center justify-between gap-3">
          <h2 className="text-sm font-medium tracking-tight">{name}</h2>
          {/* Native radios give the arrow-key and single-tab-stop behavior. */}
          <fieldset className="flex items-center gap-1.5 text-sm">
            <legend className="sr-only">{labels.billingPeriod}</legend>
            {(["month", "year"] as const).map((option, index) => (
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
                    value={option}
                    checked={interval === option}
                    onChange={() => select(option)}
                    className="peer sr-only"
                  />
                  <span className="transition-colors text-muted hover:text-foreground peer-checked:font-medium peer-checked:text-foreground peer-focus-visible:underline peer-focus-visible:underline-offset-4">
                    {option === "year" ? labels.yearly : labels.monthly}
                  </span>
                </label>
              </span>
            ))}
          </fieldset>
        </div>
      )}
      {/* The billing detail sits beside the price as a two-line label, so the
          price row keeps the Free card's height and the buttons line up. */}
      <div className="mt-3 flex items-end gap-2">
        {shown.listMonthly !== null ? (
          <s className="text-3xl font-medium tabular-nums tracking-tight text-muted decoration-1">
            {`$${formatUsd(shown.listMonthly)}`}
          </s>
        ) : null}
        <span className="text-3xl font-medium tabular-nums tracking-tight">
          {`$${formatUsd(shown.monthly)}`}
        </span>
        <span className="flex min-w-0 flex-col pb-0.5 text-sm leading-[1.15] text-muted">
          <span>{labels.perMonth}</span>
          <span className="truncate">{billing.detail}</span>
        </span>
      </div>
      <div className="mt-3">
        {action ?? (
          <ProCtaLink
            checkoutHref={checkoutHrefs[interval]}
            requiresSignIn={requiresSignIn}
            interval={interval}
            location={location}
            plan={plan}
          >
            {ctaLabel}
          </ProCtaLink>
        )}
      </div>
      {billing.yearlyBill ? (
        <p className="mt-2 text-sm text-muted">{billing.yearlyBill}</p>
      ) : null}
      {children}
    </div>
  );
}

type CardPrice = {
  /** The figure shown, per month. */
  readonly monthly: number;
  /** Today's list price per month, struck through above a lower own price. */
  readonly listMonthly: number | null;
  /** What a yearly subscription bills each year, or null for monthly. */
  readonly yearlyTotal: number | null;
};

/**
 * The line under "/mo". Founder's Edition is always named; any other own
 * price only when it is below today's list price. Otherwise the line says how
 * it is billed, so the label keeps two lines in either period and the buttons
 * line up. A yearly subscriber with such a note still sees the yearly charge,
 * under the button of their own card only. A subscriber whose own price is
 * unknown (App Store, granted, a failed lookup) gets a blank line: their card
 * does not know their period.
 */
function billingDetails({
  shown,
  currentPrice,
  labels,
  periodKnown,
}: {
  shown: CardPrice;
  currentPrice?: PlanCardSubscriptionPrice;
  labels: ProAnnualLabels;
  periodKnown: boolean;
}): { detail: string; yearlyBill: string | null } {
  const billedYearly = shown.yearlyTotal === null
    ? null
    : labels.billedYearlyTemplate.replace("{amount}", formatUsd(shown.yearlyTotal));
  const priceNote = currentPrice?.foundersEdition
    ? labels.foundersEdition
    : shown.listMonthly !== null
      ? labels.earlySupporterPrice
      : null;
  if (priceNote) return { detail: priceNote, yearlyBill: billedYearly };
  if (!periodKnown) return { detail: "\u00a0", yearlyBill: null };
  return { detail: billedYearly ?? labels.billedMonthly, yearlyBill: null };
}

function cardPrice({
  pricing,
  interval,
  currentPrice,
}: {
  pricing: Readonly<Record<BillingInterval, PlanPrice>>;
  interval: BillingInterval;
  currentPrice?: PlanCardSubscriptionPrice;
}): CardPrice {
  if (!currentPrice) {
    const list = pricing[interval];
    return {
      monthly: list.monthlyEquivalent,
      listMonthly: null,
      yearlyTotal: interval === "year" ? list.billedAmount : null,
    };
  }
  const yearly = currentPrice.interval === "year";
  const monthly = yearly ? currentPrice.amountUsd / 12 : currentPrice.amountUsd;
  // Compare against the list price for the same period, so a yearly
  // subscriber at today's yearly price is not shown a discount.
  const list = pricing[currentPrice.interval].monthlyEquivalent;
  return {
    monthly,
    listMonthly: monthly < list ? list : null,
    yearlyTotal: yearly ? currentPrice.amountUsd : null,
  };
}
