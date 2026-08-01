"use client";

import {
  createContext,
  useCallback,
  useContext,
  useRef,
  useState,
  type ReactNode,
} from "react";

import { posthog } from "../lib/posthog-client";
import {
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  type BillingInterval,
} from "../../services/billing/plans";
import { CheckoutButton } from "./checkout-navigation";
import type { PricingActionSize } from "./pricing-shared";

type PricingSurface = "public_pricing" | "app_pricing" | "dashboard_billing";
type PricingPlan = "pro" | "team";
export type PricingCheckoutHrefs = Record<BillingInterval, string>;
export type ProCheckoutHrefs = PricingCheckoutHrefs;

type PricingIntervalContextValue = {
  interval: BillingInterval;
  setInterval: (interval: BillingInterval) => void;
};

const PricingIntervalContext =
  createContext<PricingIntervalContextValue | null>(null);

export function PricingIntervalProvider({
  initialInterval,
  children,
}: {
  initialInterval: BillingInterval;
  children: ReactNode;
}) {
  return (
    <PricingIntervalState key={initialInterval} initialInterval={initialInterval}>
      {children}
    </PricingIntervalState>
  );
}

function PricingIntervalState({
  initialInterval,
  children,
}: {
  initialInterval: BillingInterval;
  children: ReactNode;
}) {
  const [interval, setInterval] = useState(initialInterval);

  return (
    <PricingIntervalContext.Provider value={{ interval, setInterval }}>
      {children}
    </PricingIntervalContext.Provider>
  );
}

export function PricingIntervalSelector({
  billingPeriodLabel,
  monthlyLabel,
  annualLabel,
  savingsLabel,
  surface,
}: {
  billingPeriodLabel: string;
  monthlyLabel: string;
  annualLabel: string;
  savingsLabel: string;
  surface: PricingSurface;
}) {
  const { interval, setInterval } = usePricingInterval();
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
      className="mx-auto mt-6 flex w-fit border border-border p-1 text-sm"
      role="group"
      aria-label={billingPeriodLabel}
    >
      <IntervalButton
        selected={interval === "month"}
        onSelect={() => {
          setInterval("month");
          capturePricingEvent(
            "cmuxterm_pricing_interval_selected",
            "month",
            surface,
          );
        }}
      >
        {monthlyLabel}
      </IntervalButton>
      <IntervalButton
        selected={interval === "year"}
        onSelect={() => {
          setInterval("year");
          capturePricingEvent(
            "cmuxterm_pricing_interval_selected",
            "year",
            surface,
          );
        }}
      >
        {annualLabel}
        <span
          className="ml-1.5 text-xs font-medium"
          style={{
            color:
              interval === "year"
                ? "var(--cmux-product-blue-on-foreground, var(--cmux-product-blue, #0088ff))"
                : "var(--cmux-product-blue-on-background, var(--cmux-product-blue, #0088ff))",
          }}
        >
          {savingsLabel}
        </span>
      </IntervalButton>
    </div>
  );
}

export function PricingIntervalValue({
  monthly,
  annual,
}: {
  monthly: ReactNode;
  annual: ReactNode;
}) {
  const { interval } = usePricingInterval();
  return interval === "year" ? annual : monthly;
}

export function PricingCheckoutButton({
  hrefs,
  children,
  location,
  plan = "pro",
  size = "default",
}: {
  hrefs: PricingCheckoutHrefs;
  children: ReactNode;
  location: string;
  plan?: PricingPlan;
  size?: PricingActionSize;
}) {
  const { interval } = usePricingInterval();
  const pricing = plan === "pro"
    ? PRO_PRICING_USD[interval]
    : TEAM_PRICING_USD[interval];

  return (
    <CheckoutButton
      href={hrefs[interval]}
      size={size}
      analytics={{
        event:
          plan === "pro"
            ? "cmuxterm_pro_cta_clicked"
            : "cmuxterm_team_cta_clicked",
        properties: {
          location,
          checkout: true,
          interval,
          currency: "usd",
          billed_amount_usd: pricing.billedAmount,
          monthly_equivalent_usd: pricing.monthlyEquivalent,
          discount_percent: pricing.discountPercent,
        },
      }}
    >
      {children}
    </CheckoutButton>
  );
}

function IntervalButton({
  selected,
  onSelect,
  children,
}: {
  selected: boolean;
  onSelect: () => void;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      aria-pressed={selected}
      onClick={onSelect}
      className={
        selected
          ? "bg-foreground px-3 py-1.5 font-medium text-background"
          : "px-3 py-1.5 text-muted transition-colors hover:text-foreground"
      }
    >
      {children}
    </button>
  );
}

function usePricingInterval() {
  const context = useContext(PricingIntervalContext);
  if (!context) {
    throw new Error(
      "Pricing interval controls must be wrapped in PricingIntervalProvider",
    );
  }
  return context;
}

function capturePricingEvent(
  event: "cmuxterm_pricing_viewed" | "cmuxterm_pricing_interval_selected",
  interval: BillingInterval,
  surface: PricingSurface,
) {
  const proPricing = PRO_PRICING_USD[interval];
  const teamPricing = TEAM_PRICING_USD[interval];
  posthog.capture(event, {
    surface,
    interval,
    currency: "usd",
    billed_amount_usd: proPricing.billedAmount,
    monthly_equivalent_usd: proPricing.monthlyEquivalent,
    discount_percent: proPricing.discountPercent,
    team_billed_amount_usd: teamPricing.billedAmount,
    team_monthly_equivalent_usd: teamPricing.monthlyEquivalent,
    team_discount_percent: teamPricing.discountPercent,
  });
}
