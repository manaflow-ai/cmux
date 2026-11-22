import {
  GO_CHECKOUT_URL,
  MAX_CHECKOUT_URL,
  PRO_CHECKOUT_URL,
  TEAM_CHECKOUT_URL,
  withCheckoutInterval,
  withCheckoutSource,
} from "@/app/lib/billing";
import { CHECKOUT_SOURCE_DASHBOARD_BILLING } from "@/services/analytics/checkoutAttribution";

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

/** Team checkout for an explicit team; the route re-checks admin. */
export function teamCheckoutHref(teamId: string): string {
  const withTeam = `${TEAM_CHECKOUT_URL}&teamId=${encodeURIComponent(teamId)}`;
  return withCheckoutInterval(withCheckoutSource(withTeam, CHECKOUT_SOURCE_DASHBOARD_BILLING), "month");
}

/** The Stripe portal for a team's payment method and invoices. */
export function teamPortalHref(teamId: string): string {
  return `/api/billing/portal?scope=team&teamId=${encodeURIComponent(teamId)}`;
}
