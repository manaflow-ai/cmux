import { and, desc, eq, inArray, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { isVaultEnabled } from "../vault/config";
import { isWebPlusPlanEnabled as isGoPlanEnabled } from "./goPlanFlag";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PERSONAL_PLAN_IDS,
  isFounderSubscriptionRow,
  isPaidPlanId,
  manualVmPlanOverride,
  resolveProPlanStatus,
  type BillingManagementKind,
  type PersonalBillingSource,
} from "./pro";
import { subscriptionPriceFromRaw, type SubscriptionPrice } from "./subscriptionPrice";
import type { TeamBillingAccessUser, TeamBillingRole } from "./teamBillingAccess";
import type { TeamEnterpriseDeal } from "./teamEnterprise";
import {
  listBillingTeams,
  loadTeamBillingView,
  selectedBillingTeamId,
  type BillingTeamListUser,
  type BillingTeamSummary,
  type TeamBillingView,
} from "./teamBillingView";
import { billingTeamFromUnknown } from "./teamResolution";
import {
  NEXT_PLAN_METADATA_KEY,
  higherNextPlanId,
  nextPlanCheckoutAvailability,
  nextGrantPlanIdFromMetadata,
  nextPlanId,
  type NextPlanId,
} from "./nextPlans";

/** The personal (Pro/Max) subscription the billing screen shows. */
export type PersonalSubscriptionJson = {
  readonly plan: string | null;
  readonly status: string;
  /** ISO timestamp, or null when Stripe sent none. */
  readonly currentPeriodEnd: string | null;
  readonly cancelAtPeriodEnd: boolean;
  readonly price: SubscriptionPrice | null;
};

export type PersonalBillingJson = {
  readonly planStatus: {
    readonly isPro: boolean;
    readonly planId: string;
    readonly billingManagement: BillingManagementKind;
    /** Who bills the plan; an `apple` plan is managed in the App Store. */
    readonly billingSource: PersonalBillingSource;
    readonly manageUrl: string | null;
    /**
     * The account owns Founder's Edition, Pro for life from a one-time
     * purchase. It is not `subscription`, so it has nothing to switch or cancel.
     */
    readonly foundersEdition: boolean;
  };
  readonly subscription: PersonalSubscriptionJson | null;
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
  readonly enterprise: TeamEnterpriseDeal | null;
};

/** `TeamBillingView` on the wire: dates are ISO strings. */
export type TeamBillingViewJson =
  | ReadyTeamBillingViewJson
  | { readonly status: "personal" }
  | { readonly status: "not_found"; readonly teamId: string }
  | { readonly status: "unavailable"; readonly teamId: string };

/** The account's cmux NEXT Cloud plan and which NEXT plans checkout can sell. */
export type NextCloudBillingJson = {
  readonly planId: NextPlanId | null;
  /** `subscription` when billed, `grant` when an operator granted it. */
  readonly source: "subscription" | "grant" | null;
  /** False while the plan's Price env var is unset: shown as Coming soon. */
  readonly checkoutAvailable: Readonly<Record<NextPlanId, boolean>>;
};

/** Wire shape of `GET /api/dashboard/billing`. */
export type DashboardBillingResponse = {
  readonly selectedTeamId: string;
  /** Set when the selected scope is the personal entry. */
  readonly personal: PersonalBillingJson | null;
  /** Set when the selected scope is a real team. */
  readonly team: TeamBillingViewJson | null;
  readonly teams: readonly BillingTeamSummary[];
  /**
   * The signed-in account's cmux NEXT Cloud plan, whichever scope is
   * selected. Optional on the wire so an older server's answer still parses.
   */
  readonly next?: NextCloudBillingJson;
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
  const next = nextCloudBilling(user.clientReadOnlyMetadata);
  if (selectedTeamId === user.id) {
    return { selectedTeamId, personal: await loadPersonalBilling(user), team: null, teams, next };
  }
  return {
    selectedTeamId,
    personal: null,
    team: teamBillingViewJson(await loadTeamBillingView(user, selectedTeamId)),
    teams,
    next,
  };
}

/**
 * The cmux NEXT plan from the account's metadata: a subscription mirror
 * (`cmuxNextPlan`, else a NEXT value in `cmuxPlan`) or an operator grant
 * (`cmuxNextVmPlan`, else a legacy NEXT id in `cmuxVmPlan`); the higher one
 * is the plan in force.
 */
export function nextCloudBilling(
  metadata: unknown,
  env: Readonly<Record<string, string | undefined>> = process.env,
): NextCloudBillingJson {
  const record = metadata && typeof metadata === "object" && !Array.isArray(metadata)
    ? metadata as Record<string, unknown>
    : {};
  const subscribed = nextPlanId(record[NEXT_PLAN_METADATA_KEY]) ?? nextPlanId(record.cmuxPlan);
  const granted = nextGrantPlanIdFromMetadata(record);
  const planId = higherNextPlanId(subscribed, granted);
  return {
    planId,
    source: planId === null ? null : planId === subscribed ? "subscription" : "grant",
    checkoutAvailable: nextPlanCheckoutAvailability(env),
  };
}

async function loadPersonalBilling(user: DashboardBillingUser): Promise<PersonalBillingJson> {
  const [status, { subscription, foundersEdition }, goPlanEnabled] = await Promise.all([
    resolveProPlanStatus(user),
    activePersonalSubscriptions(user.id),
    isGoPlanEnabled(user.id),
  ]);
  return {
    planStatus: {
      isPro: status.isPro,
      planId: status.planId,
      billingManagement: status.billingManagement,
      billingSource: status.billingSource,
      manageUrl: status.manageUrl,
      foundersEdition,
    },
    subscription,
    goPlanEnabled,
    hasPaidManualGrant: isPaidPlanId(manualVmPlanOverride(user.clientReadOnlyMetadata)),
    vaultEnabled: isVaultEnabled(),
  };
}

/**
 * The user's current Pro/Max subscription, Max first, and whether they own
 * Founder's Edition. A Founder's Edition purchase is stored as an active Pro
 * row, but it is a one-time purchase, never the subscription.
 */
export async function activePersonalSubscriptions(
  stackUserId: string,
): Promise<{ readonly subscription: PersonalSubscriptionJson | null; readonly foundersEdition: boolean }> {
  const rows = await cloudDb()
    .select({
      id: stripeSubscriptions.id,
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
    .limit(10);
  const row = rows.find((candidate) => !isFounderSubscriptionRow(candidate));
  return {
    foundersEdition: rows.some(isFounderSubscriptionRow),
    subscription: row
      ? {
          plan: row.plan ?? null,
          status: row.status,
          currentPeriodEnd: isoDate(row.currentPeriodEnd),
          cancelAtPeriodEnd: row.cancelAtPeriodEnd === true,
          price: subscriptionPriceFromRaw(row.raw),
        }
      : null,
  };
}

export function teamBillingViewJson(view: TeamBillingView): TeamBillingViewJson {
  if (view.status !== "ready") return view;
  const { subscription } = view;
  return {
    ...view,
    subscription: subscription
      ? { ...subscription, currentPeriodEnd: isoDate(subscription.currentPeriodEnd) }
      : null,
  };
}

function isoDate(value: Date | string | null | undefined): string | null {
  if (!value) return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}
