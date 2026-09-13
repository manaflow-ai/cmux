import { and, desc, eq, inArray } from "drizzle-orm";
import { z } from "zod";

import { cloudDb } from "../../../db/client";
import { stripeCustomers, stripeSubscriptions } from "../../../db/schema";
import { isStripeBillingConfigured } from "../../../services/billing/stripe";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PRO_PLAN_ID,
  TEAM_PLAN_ID,
  isPaidPlanId,
  manualVmPlanOverride,
  resolveProPlanStatus,
} from "../../../services/billing/pro";
import { resolveBillingTeam } from "../../../services/billing/teamResolution";
import { os, requireAuth } from "../base";

const subscriptionSchema = z.object({
  id: z.string(),
  status: z.string(),
  priceId: z.string().nullable(),
  seats: z.number().nullable(),
  currentPeriodEnd: z.string().nullable(),
  cancelAtPeriodEnd: z.boolean(),
});

const billingStatusSchema = z.object({
  billingAvailable: z.boolean(),
  personal: z.object({
    planId: z.enum(["free", "pro"]),
    isPro: z.boolean(),
    billingManagement: z.enum(["stripe", "external", "none"]),
    hasPaidManualGrant: z.boolean(),
    subscription: subscriptionSchema.nullable(),
  }),
  team: z.object({
    id: z.string(),
    name: z.string(),
    subscription: subscriptionSchema.nullable(),
    hasCustomer: z.boolean(),
  }).nullable(),
});

type BillingSubscription = {
  id: string;
  status: string;
  priceId: string | null;
  seats: number | null;
  currentPeriodEnd: Date | null;
  cancelAtPeriodEnd: boolean;
};

export const billingStatusProcedure = os
  .route({
    method: "GET",
    path: "/dashboard/billing/status",
    operationId: "dashboard.billing.status",
    summary: "Get the authenticated user's billing status",
    tags: ["Dashboard"],
    successStatus: 200,
  })
  .output(billingStatusSchema)
  .use(requireAuth)
  .handler(async ({ context }) => {
    const user = context.user;
    const [status, subscription, billingTeam] = await Promise.all([
      resolveProPlanStatus(user),
      latestSubscription(user.id, "user", PRO_PLAN_ID),
      resolveBillingTeam(user),
    ]);
    const teamSubscription = billingTeam
      ? await latestSubscription(billingTeam.id, "team", TEAM_PLAN_ID)
      : null;
    const hasCustomer = billingTeam
      ? (await cloudDb().select({ id: stripeCustomers.id }).from(stripeCustomers).where(eq(stripeCustomers.stackTeamId, billingTeam.id)).limit(1)).length > 0
      : false;
    return {
      billingAvailable: isStripeBillingConfigured(),
      personal: {
        planId: status.planId,
        isPro: status.isPro,
        billingManagement: status.billingManagement,
        hasPaidManualGrant: isPaidPlanId(manualVmPlanOverride(user.clientReadOnlyMetadata)),
        subscription: serializeSubscription(subscription),
      },
      team: billingTeam ? {
        id: billingTeam.id,
        name: billingTeam.displayName ?? "Team",
        subscription: serializeSubscription(teamSubscription),
        hasCustomer,
      } : null,
    };
  });

async function latestSubscription(
  ownerId: string,
  scope: "user" | "team",
  plan: typeof PRO_PLAN_ID | typeof TEAM_PLAN_ID,
): Promise<BillingSubscription | null> {
  const rows = await cloudDb()
    .select({
      id: stripeSubscriptions.id,
      status: stripeSubscriptions.status,
      priceId: stripeSubscriptions.priceId,
      seats: stripeSubscriptions.seats,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
    })
    .from(stripeSubscriptions)
    .where(and(
      scope === "user" ? eq(stripeSubscriptions.stackUserId, ownerId) : eq(stripeSubscriptions.stackTeamId, ownerId),
      eq(stripeSubscriptions.scope, scope),
      eq(stripeSubscriptions.plan, plan),
      inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
    ))
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

function serializeSubscription(subscription: BillingSubscription | null) {
  return subscription ? {
    ...subscription,
    currentPeriodEnd: subscription.currentPeriodEnd?.toISOString() ?? null,
  } : null;
}
