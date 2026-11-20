import { stripe, resolvePersonalPlanSwitchPortalConfiguration } from "./stripe";
import { stripeBillingStatusForUser, type StripeBillingStatus } from "./pro";
import {
  dashboardChangeURL,
  existingSubscriptionRoute,
  hasExistingPersonalSubscription,
} from "./personalSwitchRoute";
import { captureBillingPlanSwitchStarted } from "../analytics/stripeBilling";
import { forwardCheckoutAttribution, type CheckoutAttribution } from "../analytics/checkoutAttribution";

type SwitchTarget = "go" | "pro" | "max";

/** The same authenticated portal destination for browser and CLI upgrades. */
export async function personalPortalSession(input: {
  userId: string;
  origin: string;
  target: SwitchTarget;
  attribution: CheckoutAttribution;
  /** A billing status the caller already read for this user. */
  status?: StripeBillingStatus;
}) {
  const status = input.status ?? await stripeBillingStatusForUser(input.userId);
  if (!status.customerId) throw new Error("Billing customer is unavailable");
  const canSwitch = existingSubscriptionRoute(status, input.target) === "portal_switch";
  const session = await stripe().billingPortal.sessions.create({
    customer: status.customerId,
    return_url: new URL("/dashboard/billing", input.origin).toString(),
    ...(canSwitch ? {
      configuration: await resolvePersonalPlanSwitchPortalConfiguration(),
      flow_data: { type: "subscription_update" as const, subscription_update: { subscription: status.subscriptionId! } },
    } : {}),
  });
  if (canSwitch) await captureBillingPlanSwitchStarted({
    sessionId: session.id, userId: input.userId, fromPlan: status.activePlanId,
    targetPlan: input.target, attribution: input.attribution, livemode: session.livemode,
  });
  return session;
}

/**
 * Where a `flow=switch_plan` portal link goes when the hosted switch cannot
 * do it, or null when the portal handles it. An account with no subscription
 * to switch (a grant, Founder's Edition, or none) buys the plan through
 * checkout; a subscription the portal cannot switch opens the dashboard's
 * dialog. Links like this come from older pages and bookmarks.
 */
export function personalSwitchLinkRedirect(input: {
  status: StripeBillingStatus;
  origin: string;
  target: SwitchTarget;
  /** The link's query; only its checkout attribution parameters carry over. */
  searchParams: URLSearchParams;
}): URL | null {
  if (!hasExistingPersonalSubscription(input.status)) {
    const checkout = new URL("/api/billing/checkout", input.origin);
    checkout.searchParams.set("plan", input.target);
    forwardCheckoutAttribution(input.searchParams, checkout);
    return checkout;
  }
  return existingSubscriptionRoute(input.status, input.target) === "dashboard"
    ? dashboardChangeURL(input.origin, input.target)
    : null;
}
