// Where a request to move a personal Stripe subscription to another plan
// goes. The checkout route and the portal route both decide with these
// functions, so a link one of them sends to the other always lands on the
// same answer and never loops.

import { isPortalSwitchableLookupKey } from "./plans";
import {
  GO_PLAN_ID,
  PRO_PLAN_ID,
  isStripePortalRecoverable,
  type PersonalPlanId,
  type StripeBillingStatus,
} from "./pro";

/**
 * Whether the account has a subscription the portal should handle: one that
 * grants a plan now, or one it can still recover. Otherwise a plan request is
 * a new purchase through checkout.
 */
export function hasExistingPersonalSubscription(status: StripeBillingStatus): boolean {
  return status.hasRecurringSubscription === true || isStripePortalRecoverable(status);
}

/**
 * - `portal_switch`: the hosted portal's switch flow can do it (the
 *   subscription is on a price the portal lists, billed monthly).
 * - `dashboard`: the dashboard does it. Its switch dialog prices any
 *   subscription and keeps a yearly interval; for a Founder leaving Max it
 *   ends the Max subscription, since Founder's Edition already includes Pro.
 * - `portal`: no switch applies (same plan, Go, a scheduled cancellation or a
 *   payment to fix), so the plain portal manages the subscription.
 */
export type ExistingSubscriptionRoute = "portal_switch" | "dashboard" | "portal";

export function existingSubscriptionRoute(
  status: StripeBillingStatus,
  plan: PersonalPlanId,
): ExistingSubscriptionRoute {
  const canSwitch = plan !== GO_PLAN_ID &&
    status.hasRecurringSubscription === true &&
    status.subscriptionId !== null &&
    (status.subscriptionStatus === "active" || status.subscriptionStatus === "trialing") &&
    // A switch keeps a scheduled cancellation; the plain portal offers Renew.
    !status.cancelAtPeriodEnd &&
    status.activePlanId !== plan;
  if (!canSwitch) return "portal";
  if (status.hasFoundersEdition === true && plan === PRO_PLAN_ID) return "dashboard";
  // The shared portal offers both Max intervals, so a yearly subscriber could
  // land on monthly there, and it cannot switch a price it does not list.
  if (status.subscriptionInterval === "year" || !isPortalSwitchableLookupKey(status.planLookupKey)) {
    return "dashboard";
  }
  return "portal_switch";
}

/** The dashboard billing page with the switch (or Founder's end-Max) dialog for `plan` open. */
export function dashboardChangeURL(origin: string, plan: PersonalPlanId): URL {
  const url = new URL("/dashboard/billing", origin);
  url.searchParams.set("change", plan);
  return url;
}
