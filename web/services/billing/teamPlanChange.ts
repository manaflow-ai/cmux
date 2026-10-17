// In-place switch between the two team plans, Team and Team Max. Like the
// personal switch (planChange.ts), it swaps the Price on the subscription's
// plan item and keeps its seats: an upgrade takes effect now and invoices
// the prorated difference now; a downgrade takes effect now and credits the
// unused time to later invoices. The preview and the change share one
// proration date, so the amount shown is the amount charged. Callers
// authorize the team admin first (resolveTeamBillingAccess).

import type Stripe from "stripe";
import {
  PlanChangeError,
  chargeProrationDate,
  isCardError,
  prorationBehavior,
  prorationCredit,
  type PlanChangePreview,
} from "./planChange";
import { TEAM_MAX_PRICING_USD, TEAM_PRICING_USD } from "./plans";
import { planTierRank } from "./planTier";
import { isTeamPlanId, stripeBillingStatusForTeam, type StripeBillingStatus, type TeamPlanId } from "./pro";
import { applySubscriptionUpdate } from "./purchase";
import { resolveTeamMaxPrice, resolveTeamPrice, stripe } from "./stripe";
import { teamPlanIdForSubscription } from "./subscriptionPlan";
import { planItem } from "./subscriptionItems";

export type TeamPlanChangePreview = Omit<PlanChangePreview, "plan"> & { readonly plan: TeamPlanId };

export type TeamPlanChangeDependencies = {
  readonly billingStatus: (stackTeamId: string) => Promise<StripeBillingStatus>;
  readonly priceFor: (plan: TeamPlanId) => Promise<string>;
  readonly stripe: () => Pick<Stripe, "subscriptions" | "invoices">;
  readonly now: () => number;
  /** Stores the updated subscription the way the Stripe webhook would. */
  readonly syncSubscription: (subscription: Stripe.Subscription) => Promise<unknown>;
};

const defaultDependencies: TeamPlanChangeDependencies = {
  billingStatus: stripeBillingStatusForTeam,
  priceFor: (plan) => (plan === "team_max" ? resolveTeamMaxPrice("month") : resolveTeamPrice("month")),
  stripe,
  now: () => Math.floor(Date.now() / 1000),
  syncSubscription: (subscription) => applySubscriptionUpdate(subscription),
};

/** Per-seat monthly price in minor units. */
const MONTHLY_SEAT_AMOUNT: Readonly<Record<TeamPlanId, number>> = {
  team: TEAM_PRICING_USD.month.billedAmount * 100,
  team_max: TEAM_MAX_PRICING_USD.month.billedAmount * 100,
};

type TeamSwitch = {
  readonly customerId: string;
  readonly subscription: Stripe.Subscription;
  readonly itemId: string;
  readonly quantity: number;
  readonly price: string;
  readonly direction: "upgrade" | "downgrade";
  readonly periodEnd: number | null;
};

function assertActiveTeamSubscription(status: StripeBillingStatus, target: TeamPlanId): string {
  const active = ["active", "trialing"].includes(status.subscriptionStatus ?? "");
  if (!status.subscriptionId || !active) throw new PlanChangeError("no_subscription");
  if (status.cancelAtPeriodEnd) throw new PlanChangeError("cancel_scheduled");
  if (status.teamPlanId === target) throw new PlanChangeError("same_plan");
  return status.subscriptionId;
}

/**
 * The live subscription must be this team's monthly team subscription: a
 * personal subscription is never touched, and a grandfathered annual Team
 * subscription is not moved to a monthly Price in place.
 */
function switchableItem(subscription: Stripe.Subscription, teamId: string, target: TeamPlanId) {
  if (subscription.cancel_at_period_end) throw new PlanChangeError("cancel_scheduled");
  const metadata = subscription.metadata ?? {};
  if (!isTeamPlanId(metadata.plan) || metadata.stackTeamId !== teamId) throw new PlanChangeError("not_switchable");
  const item = planItem(subscription);
  if (!item) throw new PlanChangeError("no_subscription");
  const interval = item.price?.recurring?.interval;
  if (interval !== undefined && interval !== "month") throw new PlanChangeError("not_switchable");
  const current = teamPlanIdForSubscription(subscription);
  if (current === target) throw new PlanChangeError("same_plan");
  return { item, current };
}

async function resolveTeamSwitch(
  teamId: string,
  target: TeamPlanId,
  deps: TeamPlanChangeDependencies,
): Promise<TeamSwitch> {
  const subscriptionId = assertActiveTeamSubscription(await deps.billingStatus(teamId), target);
  const subscription = await deps.stripe().subscriptions.retrieve(subscriptionId);
  const { item, current } = switchableItem(subscription, teamId, target);
  const customerId = typeof subscription.customer === "string" ? subscription.customer : subscription.customer?.id;
  if (!customerId) throw new PlanChangeError("no_subscription");
  return {
    customerId,
    subscription,
    itemId: item.id,
    quantity: typeof item.quantity === "number" && item.quantity > 0 ? item.quantity : 1,
    price: await deps.priceFor(target),
    direction: planTierRank(target) > planTierRank(current) ? "upgrade" : "downgrade",
    periodEnd: typeof item.current_period_end === "number" ? item.current_period_end : null,
  };
}

/**
 * Only the Price changes. The quantity is left out so Stripe keeps the
 * item's live seat count; sending the count read a moment ago could undo a
 * concurrent seat reconcile.
 */
function swappedItems(change: TeamSwitch) {
  return [{ id: change.itemId, price: change.price }];
}

export async function previewTeamPlanChange(
  input: { readonly teamId: string; readonly target: TeamPlanId },
  deps: TeamPlanChangeDependencies = defaultDependencies,
): Promise<TeamPlanChangePreview> {
  const change = await resolveTeamSwitch(input.teamId, input.target, deps);
  const prorationDate = deps.now();
  const invoice = await deps.stripe().invoices.createPreview({
    customer: change.customerId,
    subscription: change.subscription.id,
    subscription_details: {
      items: swappedItems(change),
      proration_behavior: prorationBehavior(change.direction),
      proration_date: prorationDate,
    },
  });
  const upgrade = change.direction === "upgrade";
  return {
    plan: input.target,
    direction: change.direction,
    currency: invoice.currency,
    amountDueToday: upgrade ? invoice.amount_due : 0,
    credit: upgrade ? 0 : prorationCredit(invoice),
    nextRenewalAt: change.periodEnd === null ? null : new Date(change.periodEnd * 1000).toISOString(),
    nextInvoiceAmount: upgrade ? MONTHLY_SEAT_AMOUNT[input.target] * change.quantity : invoice.amount_due,
    prorationDate,
  };
}

export async function applyTeamPlanChange(
  input: { readonly teamId: string; readonly target: TeamPlanId; readonly prorationDate: number },
  deps: TeamPlanChangeDependencies = defaultDependencies,
): Promise<{ readonly plan: TeamPlanId }> {
  const change = await resolveTeamSwitch(input.teamId, input.target, deps);
  let updated: Stripe.Subscription;
  try {
    updated = await deps.stripe().subscriptions.update(change.subscription.id, {
      items: swappedItems(change),
      proration_behavior: prorationBehavior(change.direction),
      proration_date: chargeProrationDate(input.prorationDate, deps.now()),
      // An upgrade that cannot be paid fails whole instead of leaving an
      // unpaid invoice on a changed plan.
      payment_behavior: "error_if_incomplete",
      metadata: { ...change.subscription.metadata, plan: input.target },
    });
  } catch (error) {
    if (isCardError(error)) throw new PlanChangeError("payment_failed");
    throw error;
  }
  await deps.syncSubscription(updated);
  return { plan: input.target };
}
