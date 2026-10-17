"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
  type Ref,
} from "react";
import { posthog } from "../lib/posthog-client";
import {
  GO_PRICING_USD,
  MAX_PRICING_USD,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  type BillingInterval,
} from "../../services/billing/plans";
import { CheckoutButton } from "./checkout-navigation";
import {
  CHECKOUT_PLACEMENT_PARAM,
  checkoutAttributionParamsFrom,
  withCheckoutAttribution,
} from "../../services/analytics/checkoutAttribution";
import { withExternalBrowserIntent } from "../lib/billing";
import { vaultSignInHref } from "../lib/vault-auth";
import type { PricingActionSize } from "./pricing-shared";

type PricingSurface = "public_pricing" | "app_pricing" | "dashboard_billing";
type PricingPlan = "go" | "pro" | "max" | "team";

export type PricingCheckoutHrefs = Partial<Record<BillingInterval, string>>;

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
  const [interval, setInterval] = useState(initialInterval);
  return (
    <PricingIntervalContext.Provider value={{ interval, setInterval }}>
      {children}
    </PricingIntervalContext.Provider>
  );
}

export function usePricingIntervalContext(): PricingIntervalContextValue | null {
  return useContext(PricingIntervalContext);
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
  const context = usePricingIntervalContext();
  const interval = context?.interval ?? "month";
  const setPricingInterval = context?.setInterval;
  const monthlyButton = useRef<HTMLButtonElement>(null);
  const annualButton = useRef<HTMLButtonElement>(null);
  const selectInterval = useCallback((nextInterval: BillingInterval) => {
    setPricingInterval?.(nextInterval);
    capturePricingEvent("cmuxterm_pricing_interval_selected", nextInterval, surface);
  }, [setPricingInterval, surface]);
  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    let nextInterval: BillingInterval | null = null;
    if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key)) {
      nextInterval = interval === "month" ? "year" : "month";
    } else if (event.key === "Home") {
      nextInterval = "month";
    } else if (event.key === "End") {
      nextInterval = "year";
    }
    if (!nextInterval) return;
    event.preventDefault();
    selectInterval(nextInterval);
    (nextInterval === "month" ? monthlyButton : annualButton).current?.focus();
  };

  return (
    <div
      className="mx-auto mt-6 flex w-fit border border-border p-1 text-sm"
      role="radiogroup"
      aria-label={billingPeriodLabel}
      onKeyDown={handleKeyDown}
    >
      <IntervalButton
        buttonRef={monthlyButton}
        selected={interval === "month"}
        onSelect={() => selectInterval("month")}
      >
        {monthlyLabel}
      </IntervalButton>
      <IntervalButton
        buttonRef={annualButton}
        selected={interval === "year"}
        onSelect={() => selectInterval("year")}
      >
        {annualLabel}
        <span className="ml-1.5 text-xs font-medium text-[var(--cmux-product-blue-on-background,var(--cmux-product-blue,#0088ff))]">
          {savingsLabel}
        </span>
      </IntervalButton>
    </div>
  );
}

function IntervalButton({
  buttonRef,
  selected,
  onSelect,
  children,
}: {
  buttonRef: Ref<HTMLButtonElement>;
  selected: boolean;
  onSelect: () => void;
  children: ReactNode;
}) {
  return (
    <button
      ref={buttonRef}
      type="button"
      role="radio"
      aria-checked={selected}
      tabIndex={selected ? 0 : -1}
      onClick={onSelect}
      className={selected
        ? "bg-foreground px-3 py-1.5 font-medium text-background"
        : "px-3 py-1.5 text-muted transition-colors hover:text-foreground"}
    >
      {children}
    </button>
  );
}

export function PricingIntervalValue({
  monthly,
  annual,
}: {
  monthly: ReactNode;
  annual: ReactNode;
}) {
  return usePricingIntervalContext()?.interval === "year" ? annual : monthly;
}

/** Capture the initial billing period for pricing-view analytics. */
export function PricingView({
  children,
  surface,
  interval = "month",
}: {
  children: ReactNode;
  surface: PricingSurface;
  interval?: BillingInterval;
}) {
  const capturedView = useRef(false);
  useEffect(() => {
    if (capturedView.current) return;
    capturedView.current = true;
    posthog.capture("cmuxterm_pricing_viewed", {
      surface,
      interval,
      currency: "usd",
      billed_amount_usd: PRO_PRICING_USD[interval].billedAmount,
      monthly_equivalent_usd: PRO_PRICING_USD[interval].monthlyEquivalent,
      discount_percent: PRO_PRICING_USD[interval].discountPercent,
      team_billed_amount_usd: TEAM_PRICING_USD[interval].billedAmount,
      team_monthly_equivalent_usd: TEAM_PRICING_USD[interval].monthlyEquivalent,
      team_discount_percent: TEAM_PRICING_USD[interval].discountPercent,
    });
  }, [interval, surface]);
  return children;
}

function planPrice(plan: PricingPlan, interval: BillingInterval) {
  if (plan === "pro") {
    return PRO_PRICING_USD[interval];
  }
  if (plan === "team") {
    return TEAM_PRICING_USD[interval];
  }
  if (plan === "max") {
    return MAX_PRICING_USD.month;
  }
  return GO_PRICING_USD.month;
}

const PLAN_CTA_EVENTS = {
  go: "cmuxterm_go_cta_clicked",
  pro: "cmuxterm_pro_cta_clicked",
  max: "cmuxterm_max_cta_clicked",
  team: "cmuxterm_team_cta_clicked",
} as const satisfies Record<PricingPlan, string>;

export function PricingCheckoutButton({
  href,
  hrefs,
  requiresSignIn = false,
  children,
  location,
  plan = "pro",
  interval = "month",
  size = "default",
}: {
  href?: string;
  hrefs?: PricingCheckoutHrefs;
  /** Signed-out visitors authenticate before the server checks subscription state. */
  requiresSignIn?: boolean;
  children: ReactNode;
  location: string;
  plan?: PricingPlan;
  interval?: BillingInterval;
  size?: PricingActionSize;
}) {
  const sharedInterval = usePricingIntervalContext()?.interval;
  const selectedInterval = sharedInterval ?? interval;
  const pricing = planPrice(plan, selectedInterval);
  const checkoutHref = hrefs?.[selectedInterval] ?? href;
  if (!checkoutHref) throw new Error("Pricing checkout requires href or hrefs");
  return (
    <CheckoutButton
      href={pricingDestination(checkoutHref, location, requiresSignIn)}
      resolveHref={() =>
        pricingDestination(
          withCheckoutAttribution(
            checkoutHref,
            checkoutAttributionParamsFrom(
              Object.fromEntries(new URLSearchParams(window.location.search)),
            ),
          ),
          location,
          requiresSignIn,
        )
      }
      size={size}
      onClick={() => {
        if (requiresSignIn) {
          posthog.capture("cmuxterm_pricing_sign_in_required", {
            plan,
            location,
            interval: plan === "pro" || plan === "team" ? selectedInterval : "month",
            currency: "usd",
            billed_amount_usd: pricing.billedAmount,
          });
        }
      }}
      analytics={{
        event: PLAN_CTA_EVENTS[plan],
        properties: {
          location,
          plan,
          checkout: !requiresSignIn,
          auth_required: requiresSignIn,
          interval: plan === "pro" || plan === "team" ? selectedInterval : "month",
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

/** Also used on click so a streamed offer keeps attribution before account data arrives. */
function pricingDestination(
  href: string,
  location: string,
  requiresSignIn: boolean,
) {
  const checkoutHref = withCheckoutAttribution(href, {
    [CHECKOUT_PLACEMENT_PARAM]: location,
  });
  const checkoutURL = new URL(checkoutHref, "https://cmux.com");
  checkoutURL.searchParams.set("cmux_after_sign_in", "1");
  const signInHref = vaultSignInHref(
    `${checkoutURL.pathname}${checkoutURL.search}`,
  );
  return requiresSignIn
    ? checkoutURL.searchParams.get("cmux_external_browser") === "1"
      ? withExternalBrowserIntent(signInHref)
      : signInHref
    : checkoutHref;
}
