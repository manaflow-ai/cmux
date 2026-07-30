"use client";

import { useCallback, useRef } from "react";

import { posthog } from "../lib/posthog-client";
import {
  PRO_PRICING_USD,
  type ProBillingInterval,
} from "../../services/billing/plans";

type PricingSurface = "public_pricing" | "app_pricing" | "dashboard_billing";

export function PricingIntervalSelector({
  interval,
  monthlyHref,
  annualHref,
  billingPeriodLabel,
  monthlyLabel,
  annualLabel,
  savingsLabel,
  surface,
}: {
  interval: ProBillingInterval;
  monthlyHref: string;
  annualHref: string;
  billingPeriodLabel: string;
  monthlyLabel: string;
  annualLabel: string;
  savingsLabel: string;
  surface: PricingSurface;
}) {
  const capturedView = useRef(false);
  const captureView = useCallback(
    (node: HTMLDivElement | null) => {
      if (!node || capturedView.current) return;
      capturedView.current = true;
      capturePricingEvent("cmuxterm_pricing_viewed", interval, surface);
    },
    [interval, surface],
  );

  return (
    <div
      ref={captureView}
      className="mt-6 inline-flex border border-border p-1 text-sm"
      role="group"
      aria-label={billingPeriodLabel}
    >
      <IntervalLink
        href={monthlyHref}
        selected={interval === "month"}
        onSelect={() => capturePricingEvent("cmuxterm_pricing_interval_selected", "month", surface)}
      >
        {monthlyLabel}
      </IntervalLink>
      <IntervalLink
        href={annualHref}
        selected={interval === "year"}
        onSelect={() => capturePricingEvent("cmuxterm_pricing_interval_selected", "year", surface)}
      >
        {annualLabel}
        <span className="ml-1.5 text-xs opacity-75">{savingsLabel}</span>
      </IntervalLink>
    </div>
  );
}

function IntervalLink({
  href,
  selected,
  onSelect,
  children,
}: {
  href: string;
  selected: boolean;
  onSelect: () => void;
  children: React.ReactNode;
}) {
  return (
    <a
      href={href}
      aria-current={selected ? "true" : undefined}
      onClick={onSelect}
      className={
        selected
          ? "bg-foreground px-3 py-1.5 font-medium text-background"
          : "px-3 py-1.5 text-muted transition-colors hover:text-foreground"
      }
    >
      {children}
    </a>
  );
}

function capturePricingEvent(
  event: "cmuxterm_pricing_viewed" | "cmuxterm_pricing_interval_selected",
  interval: ProBillingInterval,
  surface: PricingSurface,
) {
  const pricing = PRO_PRICING_USD[interval];
  posthog.capture(event, {
    surface,
    interval,
    currency: "usd",
    billed_amount_usd: pricing.billedAmount,
    monthly_equivalent_usd: pricing.monthlyEquivalent,
    discount_percent: pricing.discountPercent,
  });
}
