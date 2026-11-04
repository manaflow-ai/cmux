import { and, eq, inArray, isNull, or } from "drizzle-orm";
import { getStackServerApp } from "../../app/lib/stack";
import { cloudDb } from "../../db/client";
import { stripeCustomers, stripeSubscriptions } from "../../db/schema";
import { activeApplePlanForUser } from "../billing/apple/entitlement";
import { hasCompanyPlanGrant } from "../billing/companyPlan";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  TEAM_PLAN_ID,
  isPaidPlanId,
  manualVmPlanOverride,
  metadataPlanId,
} from "../billing/pro";
import { stripe as stripeClient } from "../billing/stripe";
import { billingPlanIdFromMetadata } from "../billing/teamResolution";
import { listAllStackTeams } from "./auth";

/**
 * Who may keep a machine running. Everything here is evidence that someone pays
 * or was granted access; only the absence of all of it is a lapse. A paused
 * Stripe subscription keeps status `active` with `pause_collection` set, so a
 * status check alone would call it paid.
 */
export type VmOwnerPlanFacts = {
  readonly isCompanyAccount: boolean;
  readonly adminGrantPlanId: string | null;
  readonly hasLiveStripeSubscription: boolean;
  readonly hasPausedStripeSubscription: boolean;
  readonly hasApplePlan: boolean;
  readonly hasPaidTeam: boolean;
  /**
   * The machine bills to a team with other members, or to a team that no longer
   * reads back. Entitlement falls back to the caller's plan, so any member may be
   * the one paying; its creator's plan does not settle it.
   */
  readonly isSharedTeamMachine: boolean;
  /** `cmuxPlan` names a paid plan. Entitlements still honor this mirror. */
  readonly metadataPlanIsPaid: boolean;
  /** Every team read, so the Stripe check can ask about their customers too. */
  readonly teamIds: readonly string[];
};

export type VmPlanLapseDecision =
  | "keep_company"
  | "keep_admin_grant"
  | "keep_stripe"
  | "keep_apple"
  | "keep_team"
  | "keep_shared_team_machine"
  | "keep_unbacked_metadata_plan"
  | "lapsed";

export function decideVmPlanLapse(facts: VmOwnerPlanFacts): VmPlanLapseDecision {
  if (facts.isCompanyAccount) return "keep_company";
  if (isPaidPlanId(facts.adminGrantPlanId)) return "keep_admin_grant";
  if (facts.hasLiveStripeSubscription) return "keep_stripe";
  if (facts.hasApplePlan) return "keep_apple";
  if (facts.hasPaidTeam) return "keep_team";
  if (facts.isSharedTeamMachine) return "keep_shared_team_machine";
  // The mirror is written from a paused subscription too, so it proves nothing here.
  if (facts.hasPausedStripeSubscription) return "lapsed";
  // A paid mirror with no row behind it may be an older operator grant: leave it for a person.
  if (facts.metadataPlanIsPaid) return "keep_unbacked_metadata_plan";
  return "lapsed";
}

export function isStripeCollectionPaused(raw: unknown): boolean {
  if (!raw || typeof raw !== "object") return false;
  const record = raw as { pause_collection?: unknown; status?: unknown };
  return record.pause_collection != null || record.status === "paused";
}

const isActiveStatus = (status: string) => (ACTIVE_STRIPE_PRO_STATUSES as readonly string[]).includes(status);

/** Paid and not paused: the one Stripe state that keeps a machine. */
export function isLiveStripeSubscription(status: string, raw: unknown): boolean {
  return isActiveStatus(status) && !isStripeCollectionPaused(raw);
}

export type VmOwnerRef = { readonly userId: string; readonly billingTeamId: string | null };
/** Null means the owner is unknown here (another project's id, a deleted account). */
export type VmOwnerPlanLookup = (owner: VmOwnerRef) => Promise<VmOwnerPlanFacts | null>;

type SubscriptionRow = { readonly status: string; readonly raw: unknown };
type PlanTeam = { readonly id: string; readonly clientReadOnlyMetadata?: unknown };
type BillingTeam = PlanTeam & { listUsers(): Promise<readonly { readonly id: string }[]> };
type PlanUser = Parameters<typeof hasCompanyPlanGrant>[0] & { readonly clientReadOnlyMetadata?: unknown };

export type VmPlanSources = {
  readonly getUser: (userId: string) => Promise<PlanUser | null>;
  /** Every team of the user; rejects when the list is incomplete. */
  readonly listTeams: (user: PlanUser) => Promise<readonly PlanTeam[]>;
  readonly getTeam: (teamId: string) => Promise<BillingTeam | null>;
  readonly personalSubscriptions: (userId: string) => Promise<readonly SubscriptionRow[]>;
  readonly teamSubscriptions: (teamIds: readonly string[]) => Promise<readonly SubscriptionRow[]>;
  readonly hasApplePlan: (userId: string) => Promise<boolean>;
};

function hasPaidTeamMetadata(team: PlanTeam): boolean {
  return isPaidPlanId(billingPlanIdFromMetadata(team.clientReadOnlyMetadata));
}

/** Builds the lookup. Any source failure rejects, and the job then leaves the machine alone. */
export function makeVmOwnerPlanLookup(sources: VmPlanSources): VmOwnerPlanLookup {
  return async ({ userId, billingTeamId }) => {
    const user = await sources.getUser(userId);
    if (!user) return null;
    const metadata = user.clientReadOnlyMetadata;
    const teams = await sources.listTeams(user);
    // A user-billed row stores the user's own id as its billing team.
    const billedToTeam = billingTeamId && billingTeamId !== userId ? billingTeamId : null;
    const billingTeam = billedToTeam ? await sources.getTeam(billedToTeam) : null;
    const members = billingTeam ? await billingTeam.listUsers() : [];
    const allTeams = billingTeam && !teams.some((team) => team.id === billingTeam.id) ? [...teams, billingTeam] : teams;
    const teamIds = allTeams.map((team) => team.id);
    const subscriptions = await sources.personalSubscriptions(userId);
    const teamRows = teamIds.length > 0 ? await sources.teamSubscriptions(teamIds) : [];
    return {
      isCompanyAccount: hasCompanyPlanGrant(user),
      adminGrantPlanId: manualVmPlanOverride(metadata),
      hasLiveStripeSubscription: subscriptions.some((row) => isLiveStripeSubscription(row.status, row.raw)),
      hasPausedStripeSubscription: subscriptions.some((row) => isActiveStatus(row.status) && isStripeCollectionPaused(row.raw)),
      hasApplePlan: await sources.hasApplePlan(userId),
      hasPaidTeam: allTeams.some(hasPaidTeamMetadata) || teamRows.some((row) => isLiveStripeSubscription(row.status, row.raw)),
      isSharedTeamMachine: billedToTeam !== null && (!billingTeam || members.some((member) => member.id !== userId)),
      metadataPlanIsPaid: isPaidPlanId(metadataPlanId(metadata)),
      teamIds,
    };
  };
}

const subscriptionColumns = { status: stripeSubscriptions.status, raw: stripeSubscriptions.raw };

export const lookupVmOwnerPlanFacts: VmOwnerPlanLookup = (owner) => makeVmOwnerPlanLookup({
  getUser: (userId) => getStackServerApp().getUser(userId) as Promise<PlanUser | null>,
  listTeams: (user) => listAllStackTeams(user as never, undefined) as Promise<readonly PlanTeam[]>,
  getTeam: (teamId) => getStackServerApp().getTeam(teamId) as Promise<BillingTeam | null>,
  personalSubscriptions: (userId) => cloudDb().select(subscriptionColumns).from(stripeSubscriptions).where(and(
    eq(stripeSubscriptions.stackUserId, userId),
    isNull(stripeSubscriptions.stackTeamId),
    eq(stripeSubscriptions.scope, "user"),
  )),
  teamSubscriptions: (teamIds) => cloudDb().select(subscriptionColumns).from(stripeSubscriptions).where(and(
    inArray(stripeSubscriptions.stackTeamId, [...teamIds]),
    eq(stripeSubscriptions.scope, "team"),
    eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
  )),
  hasApplePlan: async (userId) => (await activeApplePlanForUser(userId)) !== null,
})(owner);

export type StripeLiveSources = {
  readonly customerIds: (userId: string, teamIds: readonly string[]) => Promise<readonly string[]>;
  readonly subscriptions: (customerId: string) => Promise<readonly { readonly status: string }[]>;
};

/**
 * The local table follows Stripe through webhooks, which can lag or be lost, for
 * team customers as much as personal ones. True when any customer of this user
 * or their teams holds a live subscription: ask before stopping a machine.
 */
export function makeStripeSaysStillLive(sources: StripeLiveSources) {
  return async (userId: string, teamIds: readonly string[]): Promise<boolean> => {
    for (const customerId of await sources.customerIds(userId, teamIds)) {
      const subscriptions = await sources.subscriptions(customerId);
      if (subscriptions.some((subscription) => isLiveStripeSubscription(subscription.status, subscription))) return true;
    }
    return false;
  };
}

export const stripeSaysStillLive = makeStripeSaysStillLive({
  customerIds: async (userId, teamIds) => {
    const personal = and(eq(stripeCustomers.stackUserId, userId), isNull(stripeCustomers.stackTeamId));
    const rows = await cloudDb().select({ id: stripeCustomers.id }).from(stripeCustomers)
      .where(teamIds.length > 0 ? or(personal, inArray(stripeCustomers.stackTeamId, [...teamIds])) : personal);
    return rows.map((row) => row.id);
  },
  subscriptions: async (customerId) =>
    (await stripeClient().subscriptions.list({ customer: customerId, status: "all", limit: 100 })).data,
});
