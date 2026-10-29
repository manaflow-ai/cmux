// Stripe labels for a Cloud VM's provider metadata (services/vms/README.md,
// "Provider tags"). Read from the stripe_subscriptions mirror through the same
// status queries the billing pages use; the only Stripe call is a cached
// product-name lookup when the stored payload did not expand the product.

import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";
import {
  FOUNDERS_PLAN_ID,
  isPaidPlanId,
  isPersonalPlanId,
  manualVmPlanOverride,
  stripeBillingStatusForTeam,
  TEAM_PLAN_ID,
  stripeBillingStatusForUser,
  type StripeBillingStatus,
} from "./pro";
import { stripe } from "./stripe";
import { formatUsd } from "./subscriptionPrice";

/** The billing scope a machine was created under (the cloud_vms row's columns). */
export type VmBillingScope = {
  readonly userId: string;
  readonly billingCustomerType: "team" | "user";
  readonly billingTeamId: string;
  readonly billingPlanId: string;
};

/**
 * `stripe`: a subscription of the billing scope matched. `admin-grant`: no
 * subscription, and an operator `cmuxVmPlan` grant is on the scope. `none`:
 * a free plan. `unmatched`: a paid plan with neither.
 */
export type VmPlanSource = "stripe" | "admin-grant" | "none" | "unmatched";

const productNames = new Map<string, string>();

/**
 * The labels: `cmuxPlanSource` always, and the `stripe*` keys only for a
 * subscription that belongs to the machine's billing scope. A Team-plan
 * machine takes the billing team's subscription and nothing else. A machine on
 * a personal plan (go, pro, max, founders) takes the creator's personal subscription;
 * that query returns personal products only (Go, Pro, Max, Founder's
 * Edition), never Team. Free and other plans read no subscription. When
 * nothing in the scope matches a paid plan, the source is `admin-grant` or
 * `unmatched` and no `stripe*` key is written.
 */
export async function vmStripeProviderTags(scope: VmBillingScope): Promise<Record<string, string>> {
  const status = await scopeBillingStatus(scope);
  // A canceled row alone does not make Stripe the plan's source.
  if (status?.subscriptionId && status.hasActiveSubscription) return { cmuxPlanSource: "stripe", ...(await stripeTags(status)) };
  if (status?.hasFoundersEdition) {
    // A lifetime purchase has no subscription to name.
    return { cmuxPlanSource: "stripe", ...(status.customerId ? { stripeCustomerId: status.customerId } : {}) };
  }
  return { cmuxPlanSource: await planSourceWithoutSubscription(scope) };
}

async function scopeBillingStatus(scope: VmBillingScope): Promise<StripeBillingStatus | null> {
  if (scope.billingPlanId === TEAM_PLAN_ID) return await stripeBillingStatusForTeam(scope.billingTeamId);
  if (isPersonalPlanId(scope.billingPlanId) || scope.billingPlanId === FOUNDERS_PLAN_ID) {
    return await stripeBillingStatusForUser(scope.userId);
  }
  return null;
}

async function stripeTags(status: StripeBillingStatus): Promise<Record<string, string>> {
  const tags: Record<string, string> = {};
  if (status.customerId) tags.stripeCustomerId = status.customerId;
  if (status.subscriptionId) tags.stripeSubscriptionId = status.subscriptionId;
  if (status.subscriptionStatus) tags.stripeSubscriptionStatus = status.subscriptionStatus;
  if (status.planPriceId) tags.stripePriceId = status.planPriceId;
  const product = await productName(status.planProduct ?? null);
  if (product) tags.stripeProduct = product;
  if (status.planPrice) tags.stripePriceUsd = `${formatUsd(status.planPrice.amountUsd)}/${status.planPrice.interval}`;
  return tags;
}

/** The product's name; the stored payload usually holds only its id. A failed lookup leaves the key off. */
async function productName(product: { readonly id: string | null; readonly name: string | null } | null): Promise<string | null> {
  if (!product) return null;
  if (product.name) return product.name;
  if (!product.id) return null;
  const cached = productNames.get(product.id);
  if (cached) return cached;
  try {
    const { name } = await stripe().products.retrieve(product.id);
    if (!name) return null;
    productNames.set(product.id, name);
    return name;
  } catch {
    return null;
  }
}

async function planSourceWithoutSubscription(scope: VmBillingScope): Promise<VmPlanSource> {
  if (!isPaidPlanId(scope.billingPlanId)) return "none";
  return (await hasOperatorGrant(scope)) ? "admin-grant" : "unmatched";
}

/**
 * An operator `cmuxVmPlan` grant where the plan came from: the billing team
 * for a Team-plan machine, the creator for a personal or other paid plan.
 */
async function hasOperatorGrant(scope: VmBillingScope): Promise<boolean> {
  if (!isStackConfigured()) return false;
  const app = getStackServerApp();
  if (scope.billingPlanId === TEAM_PLAN_ID) {
    const team = await app.getTeam(scope.billingTeamId);
    return isPaidPlanId(manualVmPlanOverride(team?.clientReadOnlyMetadata));
  }
  const user = await app.getUser(scope.userId);
  return isPaidPlanId(manualVmPlanOverride(user?.clientReadOnlyMetadata));
}
