import { and, desc, eq, inArray, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { isVaultEnabled } from "../vault/config";
import { storedSubscriptionCancellation } from "./cancellation";
import { isGoPlanEnabled } from "./goPlanFlag";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PERSONAL_PLAN_IDS,
  isPaidPlanId,
  manualVmPlanOverride,
  resolveProPlanStatus,
  type BillingManagementKind,
  type PersonalBillingSource,
} from "./pro";
import { subscriptionPriceFromRaw, type SubscriptionPrice } from "./subscriptionPrice";
import type { TeamBillingAccessUser, TeamBillingRole } from "./teamBillingAccess";
import {
  listBillingTeams,
  loadTeamBillingView,
  selectedBillingTeamId,
  type BillingTeamListUser,
  type BillingTeamSummary,
  type TeamBillingView,
} from "./teamBillingView";
import { billingTeamFromUnknown } from "./teamResolution";

/** The personal (Pro/Max) subscription the billing screen shows. */
export type PersonalSubscriptionJson = {
  readonly plan: string | null;
  readonly status: string;
  /** ISO timestamp, or null when Stripe sent none. */
  readonly currentPeriodEnd: string | null;
  /** Scheduled to stop renewing, by `cancel_at_period_end` or Stripe's `cancel_at`. */
  readonly cancelAtPeriodEnd: boolean;
  /** ISO moment access ends for a cancelled subscription, from Stripe; null while it renews. */
  readonly endsAt: string | null;
  readonly price: SubscriptionPrice | null;
};

/** The personal plan that most recently ended, shown to a Free account so it can resubscribe. */
export type EndedPersonalSubscriptionJson = {
  readonly plan: "go" | "pro" | "max";
  /** ISO moment access ended, from Stripe's `ended_at`. */
  readonly endedAt: string | null;
};

export type PersonalBillingJson = {
  readonly planStatus: {
    readonly isPro: boolean;
    readonly planId: string;
    readonly billingManagement: BillingManagementKind;
    /** Who bills the plan; an `apple` plan is managed in the App Store. */
    readonly billingSource: PersonalBillingSource;
    readonly manageUrl: string | null;
  };
  readonly subscription: PersonalSubscriptionJson | null;
  /** Set only when there is no active subscription. */
  readonly endedSubscription: EndedPersonalSubscriptionJson | null;
  readonly goPlanEnabled: boolean;
  /** A paid operator grant (pro, team, founders); "free" or unknown is not. */
  readonly hasPaidManualGrant: boolean;
  readonly vaultEnabled: boolean;
};

export type TeamBillingSubscriptionJson = {
  readonly status: string;
  readonly seats: number | null;
  readonly currentPeriodEnd: string | null;
  readonly cancelAtPeriodEnd: boolean;
  readonly endsAt: string | null;
  readonly price: SubscriptionPrice | null;
};

export type ReadyTeamBillingViewJson = {
  readonly status: "ready";
  readonly team: { readonly id: string; readonly displayName: string | null };
  readonly role: TeamBillingRole;
  readonly canManageBilling: boolean;
  readonly planId: string;
  readonly billingManagement: BillingManagementKind;
  readonly granted: boolean;
  readonly subscription: TeamBillingSubscriptionJson | null;
  readonly seats: number | null;
  readonly memberCount: number | null;
  readonly overSeat: boolean;
  readonly paymentPastDue: boolean;
};

/** `TeamBillingView` on the wire: dates are ISO strings. */
export type TeamBillingViewJson =
  | ReadyTeamBillingViewJson
  | { readonly status: "personal" }
  | { readonly status: "not_found"; readonly teamId: string }
  | { readonly status: "unavailable"; readonly teamId: string };

/** Wire shape of `GET /api/dashboard/billing`. */
export type DashboardBillingResponse = {
  readonly selectedTeamId: string;
  /** Set when the selected scope is the personal entry. */
  readonly personal: PersonalBillingJson | null;
  /** Set when the selected scope is a real team. */
  readonly team: TeamBillingViewJson | null;
  readonly teams: readonly BillingTeamSummary[];
};

export type DashboardBillingUser = Parameters<typeof resolveProPlanStatus>[0] &
  BillingTeamListUser &
  TeamBillingAccessUser & {
    readonly id: string;
    readonly clientReadOnlyMetadata?: unknown;
  };

/**
 * Everything the billing screen renders for `user`. `requestedTeamId` is the
 * `?team=` scope; it wins only when it names the personal entry or a member
 * team, then Stack's selected team, then the personal entry.
 */
export async function loadDashboardBilling(
  user: DashboardBillingUser,
  requestedTeamId: string | null,
): Promise<DashboardBillingResponse> {
  const teams = await listBillingTeams(user);
  const selectedTeamId = selectedBillingTeamId({
    userId: user.id,
    teamIds: teams.map((team) => team.id),
    stackSelectedTeamId: billingTeamFromUnknown(user.selectedTeam)?.id ?? null,
    requestedTeamId,
  });
  if (selectedTeamId === user.id) {
    return { selectedTeamId, personal: await loadPersonalBilling(user), team: null, teams };
  }
  return {
    selectedTeamId,
    personal: null,
    team: teamBillingViewJson(await loadTeamBillingView(user, selectedTeamId)),
    teams,
  };
}

async function loadPersonalBilling(user: DashboardBillingUser): Promise<PersonalBillingJson> {
  const [status, subscription, goPlanEnabled] = await Promise.all([
    resolveProPlanStatus(user),
    latestActiveStripeSubscription(user.id),
    isGoPlanEnabled(user.id),
  ]);
  const endedSubscription = subscription ? null : await latestEndedStripeSubscription(user.id);
  return {
    planStatus: {
      isPro: status.isPro,
      planId: status.planId,
      billingManagement: status.billingManagement,
      billingSource: status.billingSource,
      manageUrl: status.manageUrl,
    },
    subscription,
    endedSubscription,
    goPlanEnabled,
    hasPaidManualGrant: isPaidPlanId(manualVmPlanOverride(user.clientReadOnlyMetadata)),
    vaultEnabled: isVaultEnabled(),
  };
}

/** The user's current Pro/Max subscription, Max first. */
export async function latestActiveStripeSubscription(
  stackUserId: string,
): Promise<PersonalSubscriptionJson | null> {
  const rows = await cloudDb()
    .select({
      plan: stripeSubscriptions.plan,
      status: stripeSubscriptions.status,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
      raw: stripeSubscriptions.raw,
    })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackUserId, stackUserId),
        eq(stripeSubscriptions.scope, "user"),
        inArray(stripeSubscriptions.plan, PERSONAL_PLAN_IDS),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(
      desc(sql`${stripeSubscriptions.plan} = 'max'`),
      desc(stripeSubscriptions.currentPeriodEnd),
      desc(stripeSubscriptions.updatedAt),
    )
    .limit(1);
  const row = rows[0];
  if (!row) return null;
  const cancellation = storedSubscriptionCancellation(row);
  return {
    plan: row.plan ?? null,
    status: row.status,
    currentPeriodEnd: isoDate(row.currentPeriodEnd),
    cancelAtPeriodEnd: cancellation.cancelScheduled,
    endsAt: isoDate(cancellation.endsAt),
    price: subscriptionPriceFromRaw(row.raw),
  };
}

/** The user's most recently ended Pro/Max/Go subscription, or null. */
export async function latestEndedStripeSubscription(
  stackUserId: string,
): Promise<EndedPersonalSubscriptionJson | null> {
  const rows = await cloudDb()
    .select({
      plan: stripeSubscriptions.plan,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      raw: stripeSubscriptions.raw,
    })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackUserId, stackUserId),
        eq(stripeSubscriptions.scope, "user"),
        inArray(stripeSubscriptions.plan, PERSONAL_PLAN_IDS),
        eq(stripeSubscriptions.status, "canceled"),
      ),
    )
    .orderBy(desc(stripeSubscriptions.updatedAt))
    .limit(1);
  const row = rows[0];
  const plan = row?.plan;
  if (plan !== "go" && plan !== "pro" && plan !== "max") return null;
  return { plan, endedAt: isoDate(stripeEndedAt(row.raw) ?? row.currentPeriodEnd) };
}

function stripeEndedAt(raw: unknown): Date | null {
  const value = raw && typeof raw === "object" ? (raw as Record<string, unknown>).ended_at : null;
  return typeof value === "number" ? new Date(value * 1000) : null;
}

export function teamBillingViewJson(view: TeamBillingView): TeamBillingViewJson {
  if (view.status !== "ready") return view;
  const { subscription } = view;
  return {
    ...view,
    subscription: subscription
      ? { ...subscription, currentPeriodEnd: isoDate(subscription.currentPeriodEnd), endsAt: isoDate(subscription.endsAt) }
      : null,
  };
}

function isoDate(value: Date | string | null | undefined): string | null {
  if (!value) return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}
