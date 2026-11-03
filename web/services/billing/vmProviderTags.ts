// Stripe labels for a Cloud VM's provider metadata (services/vms/README.md,
// "Provider tags"). Read from the stripe_subscriptions mirror through the same
// status queries the billing pages use; the only Stripe call is a cached
// product-name lookup when the stored payload did not expand the product.

import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  FOUNDERS_PLAN_ID,
  GO_PLAN_ID,
  isPaidPlanId,
  isPersonalPlanId,
  MAX_PLAN_ID,
  PRO_PLAN_ID,
  manualVmPlanOverride,
  stripeBillingStatusForTeam,
  TEAM_PLAN_ID,
  stripeBillingStatusForUser,
  type StripeBillingStatus,
} from "./pro";
import { stripe } from "./stripe";
import { billingPlanIdFromMetadata } from "./teamResolution";
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

/**
 * `cmuxBillingCohort` value for a machine funded by an active Plus
 * subscription at $15 per month. Other plans, other Plus prices (the legacy
 * $20 Price), other intervals, and trialing or past-due rows get no cohort.
 */
export const PLUS_USD15_MONTH_COHORT = "plus-usd15-month";

const productNames = new Map<string, string>();
const PRODUCT_LOOKUP_TIMEOUT_MS = 5_000;

/**
 * The labels: `cmuxPlanSource`, `cmuxBillingPlan`, and `cmuxBillingCohort`
 * always (an empty value clears a stale key), and the `stripe*` keys only for
 * a subscription that belongs to the machine's billing scope. `cmuxBillingPlan`
 * is the plan of that subscription now; `cmuxPlan` stays the row's plan at
 * create. A Team-plan
 * machine takes the billing team's subscription and nothing else. A machine on
 * a personal plan (go, pro, max, founders) takes the creator's personal subscription;
 * that query returns personal products only (Go, Pro, Max, Founder's
 * Edition), never Team. Free and other plans read no subscription. When
 * nothing in the scope matches a paid plan, the source is `admin-grant` or
 * `unmatched` and no `stripe*` key is written.
 */
export async function vmStripeProviderTags(scope: VmBillingScope): Promise<Record<string, string>> {
  const teamMetadata = await billingTeamMetadata(scope);
  const status = await scopeBillingStatus(scope, teamMetadata);
  // Only a row that grants access names the subscription: a canceled row, or
  // a past-due row chosen for the portal beside another active row, does not.
  // A personal row must also be the owner's best active plan: with Founder's
  // Edition (stored as `pro`) beside Plus, the Plus row is only the portal pick.
  if (
    status?.subscriptionId && isActiveStripeStatus(status.subscriptionStatus) &&
    (scope.billingPlanId === TEAM_PLAN_ID || status.subscriptionPlanId === status.activePlanId)
  ) {
    return {
      cmuxPlanSource: "stripe",
      cmuxBillingPlan: status.subscriptionPlanId ?? "",
      cmuxBillingCohort: billingCohort(status),
      ...(await stripeTags(status)),
    };
  }
  // Founder's Edition is lifetime Pro: it funds only a Pro or Founder's machine.
  if (status?.hasFoundersEdition && (scope.billingPlanId === FOUNDERS_PLAN_ID || scope.billingPlanId === PRO_PLAN_ID)) {
    // A lifetime purchase has no subscription to name.
    return {
      cmuxPlanSource: "stripe",
      cmuxBillingPlan: FOUNDERS_PLAN_ID,
      cmuxBillingCohort: "",
      ...(status.customerId ? { stripeCustomerId: status.customerId } : {}),
    };
  }
  return { cmuxPlanSource: await planSourceWithoutSubscription(scope, teamMetadata), cmuxBillingPlan: "", cmuxBillingCohort: "" };
}

/**
 * The billing team's Stack metadata, or undefined when Stack is not
 * configured. A failed read fails the tagging step; the machine keeps its
 * create-time labels.
 */
async function billingTeamMetadata(scope: VmBillingScope): Promise<unknown> {
  if (!isStackConfigured()) return undefined;
  const team = await getStackServerApp().getTeam(scope.billingTeamId);
  return team?.clientReadOnlyMetadata;
}

/**
 * Whether the machine's plan came from its billing team's own metadata (a
 * Team purchase or an operator grant on the team) rather than from the
 * creator, mirroring `billingPlanId = team plan ?? user plan` in vms/auth.ts.
 * Max is the exception there: a personal Max purchase overrides the team.
 */
function planCameFromTeam(scope: VmBillingScope, teamMetadata: unknown): boolean {
  const teamPlanId = billingPlanIdFromMetadata(teamMetadata);
  if (!teamPlanId) return false;
  return scope.billingPlanId !== MAX_PLAN_ID || teamPlanId === MAX_PLAN_ID;
}

/** Plus at $15 per month on a paid (`active`) row; every other subscription has no cohort. */
function billingCohort(status: StripeBillingStatus): string {
  const price = status.planPrice;
  return status.subscriptionStatus === "active" &&
      status.subscriptionPlanId === GO_PLAN_ID &&
      price?.amountUsd === 15 &&
      price.interval === "month"
    ? PLUS_USD15_MONTH_COHORT
    : "";
}

async function scopeBillingStatus(scope: VmBillingScope, teamMetadata: unknown): Promise<StripeBillingStatus | null> {
  if (scope.billingPlanId === TEAM_PLAN_ID) return await stripeBillingStatusForTeam(scope.billingTeamId, { preferActive: true });
  // A personal plan id that the team granted is not funded by the creator's
  // own subscription, so that subscription must not label the machine.
  if (planCameFromTeam(scope, teamMetadata)) return null;
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
    const { name } = await stripe().products.retrieve(product.id, {}, { timeout: PRODUCT_LOOKUP_TIMEOUT_MS, maxNetworkRetries: 0 });
    if (!name) return null;
    productNames.set(product.id, name);
    return name;
  } catch {
    return null;
  }
}

function isActiveStripeStatus(status: string | null): boolean {
  return status !== null && (ACTIVE_STRIPE_PRO_STATUSES as readonly string[]).includes(status);
}

async function planSourceWithoutSubscription(scope: VmBillingScope, teamMetadata: unknown): Promise<VmPlanSource> {
  if (!isPaidPlanId(scope.billingPlanId)) return "none";
  if (planCameFromTeam(scope, teamMetadata)) {
    return isPaidPlanId(manualVmPlanOverride(teamMetadata)) ? "admin-grant" : "unmatched";
  }
  // A failed grant lookup fails the tagging step; the machine keeps its create-time labels.
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
  const override = manualVmPlanOverride(user?.clientReadOnlyMetadata);
  if (!isPaidPlanId(override)) return false;
  // A Pro override does not fund a Max machine (personalPlanIdForStatus).
  return scope.billingPlanId !== MAX_PLAN_ID || override === MAX_PLAN_ID;
}
