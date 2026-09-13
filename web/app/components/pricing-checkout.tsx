"use client";

import { useEffect, useRef, type ReactNode } from "react";
import { posthog } from "../lib/posthog-client";
import { GO_PRICING_USD, MAX_PRICING_USD, PRO_PRICING_USD, TEAM_PRICING_USD } from "../../services/billing/plans";
import { CheckoutButton } from "./checkout-navigation";
import { CHECKOUT_PLACEMENT_PARAM, withCheckoutAttribution } from "../../services/analytics/checkoutAttribution";
import type { PricingActionSize } from "./pricing-shared";

type PricingSurface = "public_pricing" | "app_pricing" | "dashboard_billing";
type PricingPlan = "go" | "pro" | "max" | "team";

/** Pricing-view analytics remain active when there is no billing-period control. */
export function PricingView({ children, surface }: { children: ReactNode; surface: PricingSurface }) {
  const capturedView = useRef(false);
  useEffect(() => {
    if (capturedView.current) return;
    capturedView.current = true;
    posthog.capture("cmuxterm_pricing_viewed", {
      surface,
      interval: "month",
      currency: "usd",
      billed_amount_usd: PRO_PRICING_USD.month.billedAmount,
      monthly_equivalent_usd: PRO_PRICING_USD.month.monthlyEquivalent,
      discount_percent: 0,
      team_billed_amount_usd: TEAM_PRICING_USD.month.billedAmount,
      team_monthly_equivalent_usd: TEAM_PRICING_USD.month.monthlyEquivalent,
      team_discount_percent: 0,
    });
  }, [surface]);
  return children;
}

const PLAN_PRICES = {
  go: GO_PRICING_USD.month,
  pro: PRO_PRICING_USD.month,
  max: MAX_PRICING_USD.month,
  team: TEAM_PRICING_USD.month,
} as const;

const PLAN_CTA_EVENTS = {
  go: "cmuxterm_go_cta_clicked",
  pro: "cmuxterm_pro_cta_clicked",
  max: "cmuxterm_max_cta_clicked",
  team: "cmuxterm_team_cta_clicked",
} as const satisfies Record<PricingPlan, string>;

export function PricingCheckoutButton({
  href,
  children,
  location,
  plan = "pro",
  size = "default",
}: {
  href: string;
  children: ReactNode;
  location: string;
  plan?: PricingPlan;
  size?: PricingActionSize;
}) {
  const pricing = PLAN_PRICES[plan];
  return (
    <CheckoutButton
      href={withCheckoutAttribution(href, { [CHECKOUT_PLACEMENT_PARAM]: location })}
      size={size}
      analytics={{
        event: PLAN_CTA_EVENTS[plan],
        properties: {
          location,
          checkout: true,
          interval: "month",
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
