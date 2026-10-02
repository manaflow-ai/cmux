import { z } from "zod";
import { captureServerEvent } from "@/services/analytics/serverEvents";
import {
  applyPersonalPlanChange,
  PlanChangeError,
  previewPersonalPlanChange,
} from "@/services/billing/planChange";
import { resolveProPlanStatus } from "@/services/billing/pro";
import { claimPendingProBilling, type ProBillingClaimUser } from "@/services/billing/purchase";
import { isStripeBillingConfigured } from "@/services/billing/stripe";
import { applySubscriptionAction, type SubscriptionAction } from "@/services/billing/subscriptionManagement";
import { resolveTeamBillingAccess, type TeamBillingAccessUser } from "@/services/billing/teamBillingAccess";
import { authed } from "./base";
import { dashboardRefusal } from "./errors";

const targetPlan = z.enum(["pro", "max"]);

export const CANCEL_REASONS = ["too_expensive", "missing_feature", "not_using", "other"] as const;

/** The viewer's personal plan: the account menu badge and the "Requires Pro" panels. */
const current = authed
  .output(z.object({
    planId: z.enum(["free", "go", "pro", "max"]),
    isPro: z.boolean(),
    billingManagement: z.enum(["stripe", "external", "none"]),
  }))
  .handler(async ({ context }) => {
    const status = await resolveProPlanStatus(context.user);
    return { planId: status.planId, isPro: status.isPro, billingManagement: status.billingManagement };
  });

const previewSchema = z.object({
  plan: targetPlan,
  direction: z.enum(["upgrade", "downgrade"]),
  currency: z.string(),
  amountDueToday: z.number().int(),
  credit: z.number().int(),
  nextRenewalAt: z.string().nullable(),
  nextInvoiceAmount: z.number().int(),
  prorationDate: z.number().int(),
});

function requireBilling() {
  if (!isStripeBillingConfigured()) throw dashboardRefusal(503, "billing_unavailable");
}

function planChangeRefusal(error: unknown): unknown {
  if (!(error instanceof PlanChangeError)) return error;
  return dashboardRefusal(error.reason === "payment_failed" ? 402 : 409, error.reason);
}

/** What switching the personal plan costs today and at the next renewal. */
const previewChange = authed
  .input(z.object({ plan: targetPlan }))
  .output(previewSchema)
  .handler(async ({ context, input }) => {
    requireBilling();
    try {
      return await previewPersonalPlanChange({ userId: context.user.id, target: input.plan });
    } catch (error) {
      throw planChangeRefusal(error);
    }
  });

/** Switch the personal plan in place, prorated as the preview showed. */
const change = authed
  .input(z.object({ plan: targetPlan, prorationDate: z.number().int() }))
  .output(z.object({ plan: targetPlan }))
  .handler(async ({ context, input }) => {
    requireBilling();
    try {
      return await applyPersonalPlanChange({ userId: context.user.id, target: input.plan, prorationDate: input.prorationDate });
    } catch (error) {
      throw planChangeRefusal(error);
    }
  });

const teamScope = z.object({ teamId: z.string().trim().min(1).max(200).optional() });

/** The subscription owner: the viewer, or a team the viewer administers. */
async function subscriptionOwner(user: TeamBillingAccessUser & { readonly id: string }, teamId: string | undefined) {
  if (!teamId) return { scope: "user" as const, ownerId: user.id, teamId: null };
  const access = await resolveTeamBillingAccess(user, teamId, { requireAdmin: true });
  if (!access.ok) {
    throw dashboardRefusal(access.error === "authorization_unavailable" ? 503 : 403, access.error);
  }
  return { scope: "team" as const, ownerId: access.team.id, teamId: access.team.id };
}

type BillingActor = TeamBillingAccessUser & ProBillingClaimUser & { readonly id: string };

async function subscriptionAction(user: BillingActor, teamId: string | undefined, action: SubscriptionAction) {
  requireBilling();
  const owner = await subscriptionOwner(user, teamId);
  // Same as /api/billing/subscription: link a purchase made under this
  // verified email before looking for the subscription. Best effort.
  if (owner.scope === "user" && user.isAnonymous !== true && user.isRestricted !== true && user.primaryEmailVerified === true && user.primaryEmail) {
    await claimPendingProBilling(user).catch(() => undefined);
  }
  const applied = await applySubscriptionAction({ scope: owner.scope, ownerId: owner.ownerId, action });
  if (!applied) throw dashboardRefusal(409, "no_subscription");
  return owner;
}

/**
 * Cancel at the end of the period (access continues until then). The reason
 * is optional and only ever goes to analytics.
 */
const cancel = authed
  .input(teamScope.extend({
    reason: z.object({
      code: z.enum(CANCEL_REASONS),
      detail: z.string().max(500).optional(),
    }).optional(),
  }))
  .output(z.object({ ok: z.literal(true) }))
  .handler(async ({ context, input }) => {
    const owner = await subscriptionAction(context.user, input.teamId, "cancel");
    if (input.reason) {
      const detail = input.reason.code === "other" ? input.reason.detail?.trim() || null : null;
      await captureServerEvent({
        event: "billing_cancel_reason",
        distinctId: context.user.id,
        teamId: owner.teamId,
        properties: { scope: owner.scope, reason: input.reason.code, detail },
      }).catch(() => undefined);
    }
    return { ok: true as const };
  });

/** Undo a scheduled cancellation before the period ends. */
const resume = authed
  .input(teamScope)
  .output(z.object({ ok: z.literal(true) }))
  .handler(async ({ context, input }) => {
    await subscriptionAction(context.user, input.teamId, "resume");
    return { ok: true as const };
  });

export const billingRouter = { current, previewChange, change, cancel, resume };
