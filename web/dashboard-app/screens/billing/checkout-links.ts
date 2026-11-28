import {
  GO_CHECKOUT_URL,
  MAX_CHECKOUT_URL,
  NEXT_MAX_CHECKOUT_PATH,
  NEXT_PLUS_CHECKOUT_PATH,
  NEXT_PRO_CHECKOUT_PATH,
  PRO_CHECKOUT_URL,
  TEAM_CHECKOUT_URL,
  withCheckoutInterval,
  withExternalBrowserIntent,
  withCheckoutSource,
} from "@/app/lib/billing";
import { CHECKOUT_SOURCE_DASHBOARD_BILLING } from "@/services/analytics/checkoutAttribution";
import type { NextPlanId } from "@/services/billing/nextPlans";

const CHECKOUT_URL: Readonly<Record<"go" | "pro" | "max", string>> = {
  go: GO_CHECKOUT_URL,
  pro: PRO_CHECKOUT_URL,
  max: MAX_CHECKOUT_URL,
};

/**
 * Stripe Checkout for a personal plan, returning to `returnTo` (a public
 * dashboard path; the server keeps it only if it is one) with a welcome.
 */
export function personalCheckoutHref(plan: "go" | "pro" | "max", returnTo: string): string {
  const href = withCheckoutSource(withCheckoutInterval(CHECKOUT_URL[plan], "month"), CHECKOUT_SOURCE_DASHBOARD_BILLING);
  return `${href}${href.includes("?") ? "&" : "?"}returnTo=${encodeURIComponent(returnTo)}`;
}

const NEXT_CHECKOUT_PATH: Readonly<Record<NextPlanId, string>> = {
  next_plus: NEXT_PLUS_CHECKOUT_PATH,
  next_pro: NEXT_PRO_CHECKOUT_PATH,
  next_max: NEXT_MAX_CHECKOUT_PATH,
};

/** Checkout for a cmux NEXT Cloud plan (monthly only), returning to `returnTo`. */
export function nextCloudCheckoutHref(plan: NextPlanId, returnTo: string): string {
  const href = withCheckoutSource(withExternalBrowserIntent(NEXT_CHECKOUT_PATH[plan]), CHECKOUT_SOURCE_DASHBOARD_BILLING);
  return `${href}&returnTo=${encodeURIComponent(returnTo)}`;
}

/** Team checkout for an explicit team; the route re-checks admin. */
export function teamCheckoutHref(teamId: string): string {
  const withTeam = `${TEAM_CHECKOUT_URL}&teamId=${encodeURIComponent(teamId)}`;
  return withCheckoutInterval(withCheckoutSource(withTeam, CHECKOUT_SOURCE_DASHBOARD_BILLING), "month");
}

/** The Stripe portal for a team's payment method and invoices. */
export function teamPortalHref(teamId: string): string {
  return `/api/billing/portal?scope=team&teamId=${encodeURIComponent(teamId)}`;
}
