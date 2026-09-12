import { stripe, resolvePersonalPlanSwitchPortalConfiguration } from "./stripe";
import { stripeBillingStatusForUser } from "./pro";
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
    status.activePlanId !== input.target;
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
    targetPlan: input.target, attribution: input.attribution,
  });
  return session;
}
