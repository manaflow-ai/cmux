import { stripe, resolvePersonalPlanSwitchPortalConfiguration } from "./stripe";
import { stripeBillingStatusForUser } from "./pro";
import { isPortalSwitchableLookupKey } from "./plans";
import { captureBillingPlanSwitchStarted } from "../analytics/stripeBilling";
import type { CheckoutAttribution } from "../analytics/checkoutAttribution";

/** The same authenticated portal destination for browser and CLI upgrades. */
export async function personalPortalSession(input: {
  userId: string;
  origin: string;
  target: "go" | "pro" | "max";
  attribution: CheckoutAttribution;
}) {
  const status = await stripeBillingStatusForUser(input.userId);
  if (!status.customerId) throw new Error("Billing customer is unavailable");
  const canSwitch = input.target !== "go" && status.hasRecurringSubscription && status.subscriptionId &&
    ["active", "trialing"].includes(status.subscriptionStatus ?? "") &&
    // A switch keeps a scheduled cancellation; the plain portal offers Renew.
    !status.cancelAtPeriodEnd &&
    // The shared portal lists both destination intervals. Keep yearly
    // subscribers in the dashboard's interval-aware flow instead of allowing
    // a direct switch to a monthly Max price.
    status.subscriptionInterval !== "year" &&
    status.activePlanId !== input.target &&
    // The switch flow fails for a price the portal does not list.
    isPortalSwitchableLookupKey(status.planLookupKey);
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
