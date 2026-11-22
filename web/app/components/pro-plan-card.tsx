"use client";

import { useId, useState, type ReactNode } from "react";
import { posthog } from "../lib/posthog-client";
import {
  PRO_PRICING_USD,
  type BillingInterval,
} from "../../services/billing/plans";
import { ProCtaLink } from "../[locale]/components/pro-cta-link";

export type ProAnnualLabels = {
  billingPeriod: string;
  yearly: string;
  monthly: string;
  perMonth: string;
  billedYearlySaving: string;
};

/**
 * The Pro pricing card. Pro is the only plan sold yearly, so the card owns the
 * billing period: its price, checkout link, and CTA analytics always agree.
 * Yearly is the default. The period toggle sits in the header row and the
 * yearly note sits under the button, so the price block and the button line
 * up with the Free and Max cards in either period.
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
  /** A link back from checkout (`?interval=month`) keeps the buyer's period. */
  initialInterval?: BillingInterval;
  children: ReactNode;
}) {
  const [chosen, setInterval] = useState<BillingInterval>(initialInterval);
  const interval = monthlyOnly ? "month" : chosen;
  const radioName = useId();
  const select = (next: BillingInterval) => {
    setInterval(next);
    posthog.capture("cmuxterm_pricing_interval_selected", {
      surface,
      plan: "pro",
      interval: next,
      billed_amount_usd: PRO_PRICING_USD[next].billedAmount,
      discount_percent: PRO_PRICING_USD[next].discountPercent,
    });
  };
  // A subscriber sees their own plan, whose period the card does not know,
  // so the monthly price stays the reference there.
  const price = PRO_PRICING_USD[action ? "month" : interval];

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
            {(["year", "month"] as const).map((option, index) => (
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
      <div className="mt-3">
        <div className="flex items-baseline gap-1.5">
          <span className="text-3xl font-medium tabular-nums tracking-tight">
            {`$${price.monthlyEquivalent}`}
          </span>
          <span className="max-w-44 text-sm leading-snug text-muted">
            {labels.perMonth}
          </span>
        </div>
      </div>
      <div className="mt-3">
        {action ?? (
          <>
            <ProCtaLink
              checkoutHref={checkoutHrefs[interval]}
              requiresSignIn={requiresSignIn}
              interval={interval}
              location={location}
            >
              {ctaLabel}
            </ProCtaLink>
            {/* Reserved in both periods so the card keeps its height. */}
            <p className="mt-2 min-h-5 text-sm text-muted">
              {interval === "year" ? labels.billedYearlySaving : null}
            </p>
          </>
        )}
      </div>
      {children}
    </div>
  );
}
