// Cancel-at-period-end and resume for recorded Stripe subscriptions. Shared by
// the self-serve billing form and the admin dashboard so both paths update
// Stripe and the local snapshot the same way.

import { and, desc, eq, inArray, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PRO_PLAN_ID,
  TEAM_PLAN_ID,
} from "./pro";
import { stripe } from "./stripe";

export type SubscriptionAction = "cancel" | "resume";
export type SubscriptionScope = "user" | "team";

export type SubscriptionUpdater = (
  subscriptionId: string,
  action: SubscriptionAction,
) => Promise<{ cancel_at_period_end?: boolean }>;

export async function activeStripeSubscriptionForStackUser(stackUserId: string) {
  const rows = await cloudDb()
    .select({ id: stripeSubscriptions.id })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackUserId, stackUserId),
        eq(stripeSubscriptions.scope, "user"),
        eq(stripeSubscriptions.plan, PRO_PLAN_ID),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

export async function activeStripeSubscriptionForStackTeam(stackTeamId: string) {
  const rows = await cloudDb()
    .select({ id: stripeSubscriptions.id })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackTeamId, stackTeamId),
        eq(stripeSubscriptions.scope, "team"),
        eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

export async function updateSubscriptionSnapshot(
  subscriptionId: string,
  subscription: { cancel_at_period_end?: boolean },
) {
  await cloudDb()
    .update(stripeSubscriptions)
    .set({
      cancelAtPeriodEnd: Boolean(subscription.cancel_at_period_end),
      raw: JSON.parse(JSON.stringify(subscription)) as Record<string, unknown>,
      updatedAt: sql`now()`,
    })
    .where(eq(stripeSubscriptions.id, subscriptionId));
}

export const stripeSubscriptionUpdater: SubscriptionUpdater = async (subscriptionId, action) =>
  await stripe().subscriptions.update(subscriptionId, {
    cancel_at_period_end: action === "cancel",
  });

/**
 * Applies cancel/resume to the active subscription for the owner and stores the
 * new snapshot. Returns false when the owner has no active subscription.
 */
export async function applySubscriptionAction(input: {
  readonly scope: SubscriptionScope;
  readonly ownerId: string;
  readonly action: SubscriptionAction;
  readonly update?: SubscriptionUpdater;
}): Promise<boolean> {
  const subscription = input.scope === "team"
    ? await activeStripeSubscriptionForStackTeam(input.ownerId)
    : await activeStripeSubscriptionForStackUser(input.ownerId);
  if (!subscription) return false;
  const updated = await (input.update ?? stripeSubscriptionUpdater)(subscription.id, input.action);
  await updateSubscriptionSnapshot(subscription.id, updated);
  return true;
}
