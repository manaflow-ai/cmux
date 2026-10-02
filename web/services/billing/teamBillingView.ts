import { and, desc, eq, inArray } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { storedSubscriptionCancellation } from "./cancellation";
import { ACTIVE_STRIPE_PRO_STATUSES, TEAM_PLAN_ID, type BillingManagementKind } from "./pro";
import { subscriptionPriceFromRaw, type SubscriptionPrice } from "./subscriptionPrice";
import {
  resolveTeamBillingAccess,
  type TeamBillingAccessUser,
  type TeamBillingRole,
  type TeamBillingStackTeam,
} from "./teamBillingAccess";
import { teamPlanStatusForTeam, type TeamPlanStatus } from "./teamPlanStatus";
import {
  billingPlanIdFromMetadata,
  billingSeatsFromMetadata,
  billingTeamFromUnknown,
} from "./teamResolution";

export type TeamBillingSubscription = {
  readonly status: string;
  readonly seats: number | null;
  readonly currentPeriodEnd: Date | null;
  /** Scheduled to stop renewing, by `cancel_at_period_end` or `cancel_at`. */
  readonly cancelAtPeriodEnd: boolean;
  /** When access ends for a cancelled subscription, from Stripe; null while it renews. */
  readonly endsAt: Date | null;
  readonly price: SubscriptionPrice | null;
};

export type ReadyTeamBillingView = {
  readonly status: "ready";
  readonly team: { readonly id: string; readonly displayName: string | null };
  readonly role: TeamBillingRole;
  readonly canManageBilling: boolean;
  readonly planId: TeamPlanStatus["planId"];
  /** "stripe" when the portal has a subscription to manage or recover. */
  readonly billingManagement: BillingManagementKind;
  /** Team access granted by an operator, with no subscription. */
  readonly granted: boolean;
  readonly subscription: TeamBillingSubscription | null;
  /** Paid seats: the live subscription quantity, else the synced metadata. */
  readonly seats: number | null;
  /** Current members, or null when Stack could not list them. */
  readonly memberCount: number | null;
  /**
   * More members than paid seats: the reconciler has not caught up yet, or
   * its last Stripe write failed. Joining is never blocked.
   */
  readonly overSeat: boolean;
  readonly paymentPastDue: boolean;
};

export type TeamBillingView =
  | ReadyTeamBillingView
  | { readonly status: "personal" }
  | { readonly status: "not_found"; readonly teamId: string }
  | { readonly status: "unavailable"; readonly teamId: string };

/**
 * Everything a team billing panel renders, for any member of `teamId`.
 * Members get a read-only view (`canManageBilling: false`); admins get the
 * actions. The personal entry (`teamId === user.id`) is not a Team billing
 * subject and returns `personal` so callers render the Pro/Max view instead.
 */
export async function loadTeamBillingView(
  user: TeamBillingAccessUser,
  teamId: string,
): Promise<TeamBillingView> {
  const access = await resolveTeamBillingAccess(user, teamId, { requireAdmin: false });
  if (!access.ok) {
    if (access.error === "personal_team_not_upgradable_to_team") return { status: "personal" };
    if (access.error === "authorization_unavailable") return { status: "unavailable", teamId };
    return { status: "not_found", teamId };
  }
  const { team } = access;
  const [planStatus, subscription, memberCount] = await Promise.all([
    teamPlanStatusForTeam(team),
    latestActiveTeamSubscription(team.id),
    teamMemberCount(team),
  ]);
  const seats = subscription?.seats ?? billingSeatsFromMetadata(team.clientReadOnlyMetadata);
  return {
    status: "ready",
    team: { id: team.id, displayName: billingTeamFromUnknown(team)?.displayName ?? null },
    role: access.role,
    canManageBilling: access.canManageBilling,
    planId: planStatus.planId,
    billingManagement: planStatus.billingManagement,
    granted: planStatus.granted,
    subscription,
    seats,
    memberCount,
    overSeat: subscription !== null && seats !== null && memberCount !== null && memberCount > seats,
    paymentPastDue: subscription?.status === "past_due",
  };
}

export async function latestActiveTeamSubscription(
  stackTeamId: string,
): Promise<TeamBillingSubscription | null> {
  const rows = await cloudDb()
    .select({
      status: stripeSubscriptions.status,
      seats: stripeSubscriptions.seats,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
      raw: stripeSubscriptions.raw,
    })
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
  const row = rows[0];
  if (!row) return null;
  const cancellation = storedSubscriptionCancellation({ ...row, currentPeriodEnd: row.currentPeriodEnd ?? null });
  return {
    status: row.status,
    seats: row.seats ?? null,
    currentPeriodEnd: row.currentPeriodEnd ?? null,
    cancelAtPeriodEnd: cancellation.cancelScheduled,
    endsAt: cancellation.endsAt,
    price: subscriptionPriceFromRaw(row.raw),
  };
}

async function teamMemberCount(team: TeamBillingStackTeam): Promise<number | null> {
  if (typeof team.listUsers !== "function") return null;
  try {
    return (await team.listUsers()).length;
  } catch {
    return null;
  }
}

/** One row of the "your teams" list on the billing page. */
export type BillingTeamSummary = {
  readonly id: string;
  readonly displayName: string | null;
  readonly personal: boolean;
  readonly planId: string | null;
};

export type BillingTeamListUser = {
  readonly id: string;
  readonly selectedTeam?: unknown;
  listTeams?(): Promise<readonly unknown[]>;
};

/** The user's real teams (selected first, deduplicated), with plan badges. */
export async function listBillingTeams(user: BillingTeamListUser): Promise<readonly BillingTeamSummary[]> {
  const listed = typeof user.listTeams === "function" ? await user.listTeams() : [];
  const seen = new Set<string>();
  const summaries: BillingTeamSummary[] = [];
  for (const raw of [user.selectedTeam, ...listed]) {
    const team = billingTeamFromUnknown(raw);
    if (!team || team.id === user.id || seen.has(team.id)) continue;
    seen.add(team.id);
    summaries.push({
      id: team.id,
      displayName: team.displayName,
      personal: false,
      planId: billingPlanIdFromMetadata(team.clientReadOnlyMetadata),
    });
  }
  return summaries;
}

/**
 * The team the billing page shows. Mirrors the dashboard team scope: an
 * explicit `?team=` wins when it names the personal entry or a member team,
 * then Stack's selected team, then the personal entry.
 */
export function selectedBillingTeamId(input: {
  readonly userId: string;
  readonly teamIds: readonly string[];
  readonly stackSelectedTeamId: string | null;
  readonly requestedTeamId: string | null;
}): string {
  const requested = input.requestedTeamId?.trim();
  if (requested && (requested === input.userId || input.teamIds.includes(requested))) return requested;
  const selected = input.stackSelectedTeamId;
  if (selected && input.teamIds.includes(selected)) return selected;
  return input.userId;
}
