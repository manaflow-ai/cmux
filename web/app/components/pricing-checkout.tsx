"use client";

import { useEffect, useRef, type ReactNode } from "react";
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
import {
  assignmentEventProperties,
  exposureEventProperties,
  isPublicPricingPath,
  pricingExposure,
  syncPricingExperimentProperties,
  type PricingExperimentAssignment,
} from "./pricing-experiment-exposure";

type PricingSurface = "public_pricing" | "app_pricing" | "dashboard_billing";
type PricingPlan = "go" | "pro" | "max" | "team";

/**
 * Pricing-view analytics remain active when there is no billing-period control.
 * On the public page the view is also the `web-pricing-v1` exposure: the
 * rendered variant is reported as PostHog's `$feature_flag_called` and
 * registered as `$feature/web-pricing-v1`, so the CTA, interval and checkout
 * events that follow carry it.
 */
export function PricingView({
  children,
  surface,
  experiment,
}: {
  children: ReactNode;
  surface: PricingSurface;
  /** The variant this page renders; omitted on surfaces outside the experiment. */
  experiment?: PricingExperimentAssignment;
}) {
  const capturedView = useRef(false);
  const experimentKey = experiment?.experiment;
  const variant = experiment?.variant;
  useEffect(() => {
    if (capturedView.current) return;
    capturedView.current = true;
    let experimentProperties: Record<string, string> = {};
    if (experimentKey && variant && isPublicPricingPath(window.location.pathname)) {
      const assignment = { experiment: experimentKey, variant };
      const exposure = pricingExposure(assignment, {
        cookies: document.cookie,
        pathname: window.location.pathname,
      });
      experimentProperties = syncPricingExperimentProperties(posthog, assignment, exposure);
      if (exposure) {
        posthog.capture("paywall_assigned", assignmentEventProperties(exposure, window.location.hostname));
        posthog.capture("$feature_flag_called", exposureEventProperties(exposure, window.location.hostname));
      }
    }
    posthog.capture("cmuxterm_pricing_viewed", {
      ...experimentProperties,
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
  }, [surface, experimentKey, variant]);
  return children;
}

function planPrice(plan: PricingPlan, interval: BillingInterval) {
  if (plan === "pro" || plan === "max") {
    return { pro: PRO_PRICING_USD, max: MAX_PRICING_USD }[plan][interval];
  }
  return { go: GO_PRICING_USD, max: MAX_PRICING_USD, team: TEAM_PRICING_USD }[plan].month;
}

const PLAN_CTA_EVENTS = {
  go: "cmuxterm_go_cta_clicked",
  pro: "cmuxterm_pro_cta_clicked",
  max: "cmuxterm_max_cta_clicked",
  team: "cmuxterm_team_cta_clicked",
} as const satisfies Record<PricingPlan, string>;

export function PricingCheckoutButton({
  href,
  requiresSignIn = false,
  children,
  location,
  plan = "pro",
  interval = "month",
  size = "default",
}: {
  href: string;
  /** Signed-out visitors authenticate before the server checks subscription state. */
  requiresSignIn?: boolean;
  children: ReactNode;
  location: string;
  plan?: PricingPlan;
  interval?: BillingInterval;
  size?: PricingActionSize;
}) {
  const pricing = planPrice(plan, interval);
  return (
    <CheckoutButton
      href={pricingDestination(href, location, requiresSignIn)}
      resolveHref={() =>
        pricingDestination(
          withCheckoutAttribution(
            href,
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
            interval: plan === "pro" || plan === "max" ? interval : "month",
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
          plan_id: plan,
          billing_period: plan === "pro" || plan === "max" ? interval : "month",
          checkout: !requiresSignIn,
          auth_required: requiresSignIn,
          interval: plan === "pro" || plan === "max" ? interval : "month",
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
