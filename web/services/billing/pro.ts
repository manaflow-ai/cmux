// cmux Pro subscription helpers.
//
// VM entitlements (services/vms/auth.ts) read the plan id from the user's
// `clientReadOnlyMetadata.cmuxPlan`, so syncing that key after a verified
// purchase is what upgrades Cloud VM limits — no VM code changes needed.
// `cmuxVmPlan` takes precedence over `cmuxPlan` there and is left untouched
// here so manual overrides survive.

import { and, desc, eq, inArray, isNull, or, sql } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeCustomers, stripeSubscriptions } from "../../db/schema";
import {
  getStackServerApp,
  isStackConfigured,
} from "../../app/lib/stack";
import {
  AccountDeletionMutationBlockedError,
  AccountDeletionUserMutationInProgressError,
  type AccountDeletionUserMutationLease,
} from "../account/deletionLock";
import {
  AccountMetadataUserUnavailableError,
  type AccountMetadataUserLoader,
  withFreshAccountMetadataUser,
} from
  "../account/metadataMutation";

export const PRO_PLAN_ID = "pro";
export const GO_PLAN_ID = "go";
// Max is Pro plus the 32 GB and 64 GB machine sizes. It is a personal
// subscription like Pro: same Stripe customer scope, same metadata mirror
// (`cmuxPlan: "max"`), and it satisfies every "is Pro" check.
export const MAX_PLAN_ID = "max";
export const TEAM_PLAN_ID = "team";
// Founder's Edition is a one-time purchase. Its completion recorder stores a
// durable active Pro row with a Founder marker, and subscription reconciliation
// skips that marker so a cancelled provider duplicate cannot clear access.
// Existing operator grants may still use `cmuxVmPlan: "founders"`; both forms
// provide Pro access without subscription-management controls.
export const FOUNDERS_PLAN_ID = "founders";
export const FREE_PLAN_ID = "free";

export function isFounderSubscriptionRow(row: { readonly id?: string | null; readonly raw?: unknown }): boolean {
  if (row.id?.startsWith("founders_")) return true;
  const raw = row.raw as { metadata?: { founders_edition?: unknown } } | null | undefined;
  return raw?.metadata?.founders_edition === "true";
}
/** Stack project used by the local cmux development server. */
export const DEVELOPMENT_STACK_PROJECT_ID = "454ecd03-1db2-4050-845e-4ce5b0cd9895";

/**
 * Local development accounts are Pro by default. This is intentionally tied
 * to the local launcher, Next's development runtime, and the non-production
 * Stack project so a misconfigured preview or production process cannot grant
 * access.
 */
export function isDevelopmentProAccessEnabled(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return env.NODE_ENV === "development" &&
    env.CMUX_LOCAL_DEV_PRO === "1" &&
    !env.VERCEL_ENV &&
    env.NEXT_PUBLIC_STACK_PROJECT_ID === DEVELOPMENT_STACK_PROJECT_ID;
}
/**
 * Plan ids an operator may write to `clientReadOnlyMetadata.cmuxVmPlan` to
 * grant Pro without a Stripe subscription. Mirrors `isPaidVmPlan` in
 * services/vms/entitlements.ts so the desktop plan and the VM plan agree.
 */
export const PAID_PLAN_IDS = [GO_PLAN_ID, PRO_PLAN_ID, MAX_PLAN_ID, TEAM_PLAN_ID, FOUNDERS_PLAN_ID] as const;
/**
 * Plans a person buys for themselves through `/api/billing/checkout`. A
 * user-scoped Stripe subscription row carries one of these in `plan`, derived
 * from its Price (see `personalPlanIdForPrice` in purchase.ts) so a portal
 * upgrade between them re-labels the row on the next webhook.
 */
export const PERSONAL_PLAN_IDS = [GO_PLAN_ID, PRO_PLAN_ID, MAX_PLAN_ID] as const;
export type PersonalPlanId = (typeof PERSONAL_PLAN_IDS)[number];
/** Higher index wins when an account has more than one active personal row. */
const PERSONAL_PLAN_RANK: Record<PersonalPlanId, number> = { go: 1, pro: 2, max: 3 };

export function isPersonalPlanId(planId: string | null | undefined): planId is PersonalPlanId {
  return typeof planId === "string" &&
    (PERSONAL_PLAN_IDS as readonly string[]).includes(planId.trim().toLowerCase());
}

/** The best of several personal plans, or null when none is given. */
export function highestPersonalPlanId(
  planIds: readonly (string | null | undefined)[],
): PersonalPlanId | null {
  let best: PersonalPlanId | null = null;
  for (const candidate of planIds) {
    if (!isPersonalPlanId(candidate)) continue;
    const normalized = candidate.trim().toLowerCase() as PersonalPlanId;
    if (!best || PERSONAL_PLAN_RANK[normalized] > PERSONAL_PLAN_RANK[best]) best = normalized;
  }
  return best;
}
export const PRO_ACCESS_ITEM_ID = "cmux-pro-access";
export const ACTIVE_STRIPE_PRO_STATUSES = ["active", "trialing", "past_due"] as const;
/** Subscription states that Stripe Billing Portal can manage or recover. */
export const STRIPE_PORTAL_RECOVERABLE_STATUSES = [
  "active",
  "trialing",
  "past_due",
  "unpaid",
] as const;

// Mirrors Stack's ReadonlyJson so ServerUser.update stays assignable.
export type ProMetadataJson =
  | null
  | boolean
  | number
  | string
  | readonly ProMetadataJson[]
  | { readonly [key: string]: ProMetadataJson };

export type ProMetadataCustomer = {
  readonly clientReadOnlyMetadata?: unknown;
  update(options: {
    clientReadOnlyMetadata: ProMetadataJson;
  }): Promise<unknown>;
};

/**
 * Mirrors billing-backed Pro access (recurring or durable Founder rows) in
 * `cmuxPlan`, and removes stale paid mirrors when that backing lapses. Operator
 * grants live independently in `cmuxVmPlan`, which is never changed here.
 * Returns the normalized metadata snapshot that was written or observed.
 */
export async function syncProPlanMetadata(
  user: ProMetadataCustomer,
  isPro: boolean,
  lease: AccountDeletionUserMutationLease,
  plan: PersonalPlanId = PRO_PLAN_ID,
): Promise<ProMetadataJson> {
  const raw = user.clientReadOnlyMetadata;
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  if (metadata.cmuxAccountDeleting === true) {
    return metadata as ProMetadataJson;
  }
  const current = metadata.cmuxPlan;

  if (isPro) {
    if (current === plan) return metadata as ProMetadataJson;
    metadata.cmuxPlan = plan;
  } else {
    // Any paid mirror value is stale once no Stripe Pro row backs it; VM
    // entitlements read cmuxPlan whenever no override is set.
    if (!isPaidPlanId(typeof current === "string" ? current : null)) return metadata as ProMetadataJson;
    delete metadata.cmuxPlan;
  }
  // Existing metadata came from Stack as JSON; the only value added is a string.
  await lease.refresh();
  await user.update({ clientReadOnlyMetadata: metadata as ProMetadataJson });
  return metadata as ProMetadataJson;
}

export type ProReconcileUser = ProMetadataCustomer & {
  readonly id?: string;
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
  readonly isAnonymous?: boolean;
  readonly isRestricted?: boolean;
};

export type ActiveStripeSubscriptionQuery = (stackUserId: string) => Promise<boolean>;
export type ActiveFounderSubscriptionQuery = (stackUserId: string) => Promise<boolean>;
/** The best active personal plan for an owner, or null when none is active. */
export type ActivePersonalPlanQuery = (stackUserId: string) => Promise<PersonalPlanId | null>;
export type StripeCustomerQuery = (stackUserId: string) => Promise<boolean>;
export type StripeBillingStatus = {
  /** The existing Stripe customer id, when one is recorded for this owner. */
  readonly customerId: string | null;
  /** The newest recorded Pro subscription state, if any. */
  readonly subscriptionStatus: string | null;
  /** The Stripe subscription id behind `subscriptionStatus`, for portal flows. */
  readonly subscriptionId: string | null;
  /**
   * The best personal plan among the owner's active rows (max beats pro),
   * or null. Team snapshots leave this null; the Team plan is not personal.
   */
  readonly activePlanId: PersonalPlanId | null;
  /** Lifetime purchases grant access but cannot be switched in Stripe. */
  readonly hasRecurringSubscription?: boolean;
  /** Whether the newest subscription is scheduled to cancel at period end. */
  readonly cancelAtPeriodEnd: boolean;
  readonly hasCustomer: boolean;
  /** Whether the newest subscription grants current Pro access. */
  readonly hasActiveSubscription: boolean;
};
export type StripeBillingStatusQuery = (
  stackUserId: string,
) => Promise<StripeBillingStatus>;
export type FreshProMetadataUserMutation = <Result>(
  userId: string,
  operation: (
    user: ProReconcileUser,
    lease: AccountDeletionUserMutationLease,
  ) => Promise<Result>,
) => Promise<Result>;
export type PendingBillingClaimResolver = (
  user: ProReconcileUser & { readonly id: string },
) => Promise<unknown>;
export type BillingManagementKind = "stripe" | "none";

export type NormalizedPersonalPlan = {
  readonly planId: typeof FREE_PLAN_ID | typeof PRO_PLAN_ID;
  readonly isPro: boolean;
  /** Stripe is the only source that enables subscription-management actions. */
  readonly billingManagement: BillingManagementKind;
};

export type ProPlanStatus = {
  /** The personal plan in force: free, pro, or max (max satisfies isPro). */
  readonly planId: typeof FREE_PLAN_ID | PersonalPlanId;
  readonly isPro: boolean;
  readonly billingManagement: BillingManagementKind;
  readonly metadataPlanId: string | null;
  readonly hasManualVmPlanOverride: boolean;
  readonly metadataChanged: boolean;
};

/**
 * Collapse verified entitlement sources into the user-facing personal plan.
 * Founder access is permanent but not subscription-managed; only an active
 * Stripe row enables Stripe billing controls.
 */
export function normalizePersonalPlan(
  metadata: unknown,
  hasActiveStripeSubscription: boolean,
  hasActiveFounderSubscription = false,
): NormalizedPersonalPlan {
  const metadataRecord = proMetadataRecord(metadata);
  const isFounder = hasEffectiveFounderEntitlement(
    metadataRecord,
    hasActiveFounderSubscription,
  );
  const isManualGrant = isPaidPlanId(manualVmPlanOverride(metadataRecord));
  const isPro = hasActiveStripeSubscription || isFounder || isManualGrant;
  return {
    planId: isPro ? PRO_PLAN_ID : FREE_PLAN_ID,
    isPro,
    billingManagement: hasActiveStripeSubscription ? "stripe" : "none",
  };
}

/** Resolve Founder's Edition only from durable account metadata. */
export function hasFounderEditionEntitlement(raw: unknown): boolean {
  const metadata = proMetadataRecord(raw);
  // `cmuxVmPlan` is the explicit, operator-owned Founder source. A bare
  // `cmuxPlan` value is only a Stripe mirror and must not become a permanent
  // entitlement when its backing row has lapsed or is absent.
  return isFounderPlanId(normalizedPlanValue(metadata.cmuxVmPlan));
}

/** Compare a plan value using the same normalization as Founder metadata. */
export function isFounderPlanId(raw: unknown): boolean {
  return normalizedPlanValue(raw) === FOUNDERS_PLAN_ID;
}

/**
 * Resolve the permanent Founder source while honoring an explicit, non-Founder
 * `cmuxVmPlan` override. This shared predicate keeps UI and side effects in
 * agreement about the effective entitlement.
 */
export function hasEffectiveFounderEntitlement(
  raw: unknown,
  hasActiveFounderSubscription = false,
): boolean {
  const metadata = proMetadataRecord(raw);
  return (
    hasFounderEditionEntitlement(metadata) ||
    (!hasManualVmOverride(metadata) && hasActiveFounderSubscription)
  );
}

/** Return whether the metadata carries a non-empty operator VM override. */
export function hasManualVmPlanOverride(raw: unknown): boolean {
  return hasManualVmOverride(proMetadataRecord(raw));
}

/**
 * Read-time reconciliation: compares the `cmuxPlan` metadata against the
 * actual Stripe Pro subscription state and syncs it in either direction.
 * Independent operator grants are preserved, but cannot back the billing mirror.
 */
export async function reconcileProPlanMetadata(
  user: ProReconcileUser,
  options: {
    hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery;
    hasActiveFounderSubscription?: ActiveFounderSubscriptionQuery;
    activePersonalPlan?: ActivePersonalPlanQuery;
    withFreshMetadataUser?: FreshProMetadataUserMutation;
  } = {},
): Promise<boolean> {
  const raw = user.clientReadOnlyMetadata;
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {};
  if (!user.id) return false;
  const activePlan = await resolveActivePersonalPlan(user.id, options);
  const founder = await founderSubscriptionForStatus(user.id, activePlan, options);
  const mirrorPlan = highestPersonalPlanId([activePlan, founder ? PRO_PLAN_ID : null]);
  if (!proMirrorNeedsReconcile(mirrorPlan, planIdFromMetadata(metadata))) return false;

  return await reconcileProMetadataIfAvailable(
    user.id,
    mirrorPlan,
    options.withFreshMetadataUser ?? withDefaultFreshProMetadataUser,
  );
}

/**
 * The active personal plan through whichever seam the caller supplied. The
 * boolean `hasActiveStripeSubscription` seam predates Max and can only say
 * "Pro or better"; callers that need the exact plan pass `activePersonalPlan`.
 */
async function resolveActivePersonalPlan(
  stackUserId: string,
  options: {
    hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery;
    activePersonalPlan?: ActivePersonalPlanQuery;
  },
): Promise<PersonalPlanId | null> {
  if (options.activePersonalPlan) return await options.activePersonalPlan(stackUserId);
  if (options.hasActiveStripeSubscription) {
    return (await options.hasActiveStripeSubscription(stackUserId)) ? PRO_PLAN_ID : null;
  }
  return await activePersonalPlanForUser(stackUserId);
}

export async function resolveProPlanStatus(
  user: ProReconcileUser,
  options: {
    hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery;
    hasActiveFounderSubscription?: ActiveFounderSubscriptionQuery;
    activePersonalPlan?: ActivePersonalPlanQuery;
    hasStripeCustomer?: StripeCustomerQuery;
    /** Optional state snapshot used by checkout and deterministic callers. */
    stripeBillingStatus?: StripeBillingStatus | StripeBillingStatusQuery;
    withFreshMetadataUser?: FreshProMetadataUserMutation;
    claimPendingBilling?: PendingBillingClaimResolver;
    /** Runtime environment override used by deterministic callers and tests. */
    environment?: Record<string, string | undefined>;
  } = {},
): Promise<ProPlanStatus> {
  // Keep ordinary plan reads read-mostly. Mutation-capable callers (for
  // example subscription actions) can opt into the ownership-claim boundary
  // explicitly; the plan API must not transfer billing rows as a side effect.
  if (
    options.claimPendingBilling &&
    user.id &&
    user.isAnonymous !== true &&
    user.isRestricted !== true &&
    user.primaryEmailVerified === true &&
    user.primaryEmail?.trim()
  ) {
    try {
      await options.claimPendingBilling(
        user as ProReconcileUser & { readonly id: string },
      );
    } catch {
      // Billing status still resolves from authoritative Stripe rows when a
      // pending ownership claim is temporarily unavailable.
    }
  }
  const metadata = proMetadataRecord(user.clientReadOnlyMetadata);
  const metadataFounderEntitlement = hasFounderEditionEntitlement(metadata);
  const metadataPlanId = planIdFromMetadata(metadata);
  const hasManualVmPlanOverride =
    hasManualVmOverride(metadata) || metadataFounderEntitlement;
  if (!user.isAnonymous && isDevelopmentProAccessEnabled(options.environment)) {
    return {
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "none",
      metadataPlanId,
      hasManualVmPlanOverride,
      metadataChanged: false,
    };
  }
  const { stripeBillingStatus, activeStripePlan, hasStripeCustomer } =
    await stripeStateForStatus(user.id, options);
  const hasActiveStripePro = activeStripePlan !== null;
  const founder = await founderSubscriptionForStatus(user.id, activeStripePlan, options);
  const mirrorPlan = highestPersonalPlanId([activeStripePlan, founder ? PRO_PLAN_ID : null]);
  const entitlementPlan = hasEffectiveFounderEntitlement(metadata, founder)
    ? highestPersonalPlanId([activeStripePlan, PRO_PLAN_ID])
    : activeStripePlan;
  const planId = personalPlanIdForStatus(entitlementPlan, manualVmPlanOverride(metadata));
  const isPro = planId !== FREE_PLAN_ID;
  const billingManagement = billingManagementForStatus(
    stripeBillingStatus,
    hasActiveStripePro,
    hasStripeCustomer,
  );
  let metadataChanged = false;

  if (
    user.id &&
    proMirrorNeedsReconcile(mirrorPlan, metadataPlanId)
  ) {
    metadataChanged = await reconcileProMetadataIfAvailable(
      user.id,
      mirrorPlan,
      options.withFreshMetadataUser ?? withDefaultFreshProMetadataUser,
    );
  }

  return {
    planId,
    isPro,
    billingManagement,
    metadataPlanId,
    hasManualVmPlanOverride,
    metadataChanged,
  };
}

async function founderSubscriptionForStatus(
  stackUserId: string | undefined,
  activePlan: PersonalPlanId | null,
  options: {
    hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery;
    activePersonalPlan?: ActivePersonalPlanQuery;
    hasActiveFounderSubscription?: ActiveFounderSubscriptionQuery;
  },
): Promise<boolean> {
  if (!stackUserId || activePlan === PRO_PLAN_ID || activePlan === MAX_PLAN_ID) return false;
  if (options.hasActiveFounderSubscription) return await options.hasActiveFounderSubscription(stackUserId);
  if (options.hasActiveStripeSubscription || options.activePersonalPlan) return false;
  return await hasActiveFounderStripeSubscription(stackUserId);
}

type StripeStateForStatus = {
  readonly stripeBillingStatus: StripeBillingStatus | null;
  readonly activeStripePlan: PersonalPlanId | null;
  /**
   * A customer row alone is not enough to open the portal. Stripe cannot
   * start a new subscription from the portal after a terminal cancellation
   * (or when the row has no subscription), so only recoverable subscription
   * states keep billing management enabled.
   */
  readonly hasStripeCustomer: boolean;
};

/** The Stripe-side facts a plan status is built from, through the caller's seams. */
async function stripeStateForStatus(
  stackUserId: string | undefined,
  options: {
    hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery;
    activePersonalPlan?: ActivePersonalPlanQuery;
    hasStripeCustomer?: StripeCustomerQuery;
    stripeBillingStatus?: StripeBillingStatus | StripeBillingStatusQuery;
  },
): Promise<StripeStateForStatus> {
  if (!stackUserId) {
    return { stripeBillingStatus: null, activeStripePlan: null, hasStripeCustomer: false };
  }
  const hasLegacyQueryOverrides = Boolean(
    options.hasActiveStripeSubscription || options.hasStripeCustomer,
  );
  const stripeBillingStatus = await resolveStripeBillingStatus(
    stackUserId,
    options.stripeBillingStatus,
    hasLegacyQueryOverrides,
  );
  const activeStripePlan = await activeStripePlanForStatus(stackUserId, options, stripeBillingStatus);
  const hasStripeCustomer = options.hasStripeCustomer
    ? await options.hasStripeCustomer(stackUserId)
    : stripeBillingStatus?.hasCustomer ?? (activeStripePlan !== null && !stripeBillingStatus);
  return { stripeBillingStatus, activeStripePlan, hasStripeCustomer };
}

/**
 * The plan in force for a person: the active Stripe plan when there is one,
 * else an operator grant (`cmuxVmPlan` set to a paid plan by the admin
 * dashboard or dev-grant.sh) which is Pro everywhere, not only for Cloud VM
 * limits, with a `max` grant being Max; else free.
 */
function personalPlanIdForStatus(
  activeStripePlan: PersonalPlanId | null,
  manualOverride: string | null,
): ProPlanStatus["planId"] {
  if (activeStripePlan === MAX_PLAN_ID || manualOverride === MAX_PLAN_ID) return MAX_PLAN_ID;
  if (activeStripePlan) return activeStripePlan;
  if (!isPaidPlanId(manualOverride)) return FREE_PLAN_ID;
  return manualOverride === MAX_PLAN_ID ? MAX_PLAN_ID : PRO_PLAN_ID;
}

/** Whether the Stripe portal has something to manage for this person. */
function billingManagementForStatus(
  stripeBillingStatus: StripeBillingStatus | null,
  hasActiveStripePro: boolean,
  hasStripeCustomer: boolean,
): BillingManagementKind {
  if (stripeBillingStatus) {
    return hasActiveStripePro || isStripePortalRecoverable(stripeBillingStatus) ? "stripe" : "none";
  }
  return hasActiveStripePro || hasStripeCustomer ? "stripe" : "none";
}

/**
 * The exact active personal plan (pro or max) through whichever seam the
 * status caller supplied. The boolean `hasActiveStripeSubscription` seam
 * predates Max and only knows "Pro or better", so it resolves to pro; the
 * billing snapshot and the database know the exact plan.
 */
async function activeStripePlanForStatus(
  stackUserId: string,
  options: {
    hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery;
    activePersonalPlan?: ActivePersonalPlanQuery;
  },
  stripeBillingStatus: StripeBillingStatus | null,
): Promise<PersonalPlanId | null> {
  if (options.activePersonalPlan) return await options.activePersonalPlan(stackUserId);
  if (options.hasActiveStripeSubscription) {
    return (await options.hasActiveStripeSubscription(stackUserId)) ? PRO_PLAN_ID : null;
  }
  if (stripeBillingStatus) {
    return stripeBillingStatus.activePlanId ??
      (stripeBillingStatus.hasActiveSubscription ? PRO_PLAN_ID : null);
  }
  return await activePersonalPlanForUser(stackUserId);
}

/**
 * Returns true only when the Stripe portal has a subscription it can manage.
 * Terminally canceled subscriptions and customer-only rows must continue to
 * the checkout flow instead.
 */
export function isStripePortalRecoverable(
  status: Pick<StripeBillingStatus, "hasCustomer" | "subscriptionStatus" | "cancelAtPeriodEnd">,
): boolean {
  if (!status.hasCustomer || !status.subscriptionStatus) return false;
  if (status.subscriptionStatus === "canceled") return false;
  return status.cancelAtPeriodEnd ||
    (STRIPE_PORTAL_RECOVERABLE_STATUSES as readonly string[]).includes(
      status.subscriptionStatus,
    );
}

async function resolveStripeBillingStatus(
  stackUserId: string,
  configured: StripeBillingStatus | StripeBillingStatusQuery | undefined,
  hasLegacyQueryOverrides: boolean,
): Promise<StripeBillingStatus | null> {
  if (configured) {
    return typeof configured === "function"
      ? await configured(stackUserId)
      : configured;
  }
  // Keep the small query seams used by existing reconciliation tests. Normal
  // application callers use the complete snapshot so terminal subscription
  // states can be distinguished from a bare customer row.
  if (hasLegacyQueryOverrides) return null;
  return await stripeBillingStatusForUser(stackUserId);
}

async function reconcileProMetadataIfAvailable(
  userId: string,
  activePlan: PersonalPlanId | null,
  withFreshMetadataUser: FreshProMetadataUserMutation,
): Promise<boolean> {
  try {
    return await withFreshMetadataUser(
      userId,
      (freshUser, lease) => reconcileFreshProMetadata(freshUser, activePlan, lease),
    );
  } catch (error) {
    if (
      error instanceof AccountDeletionMutationBlockedError ||
      error instanceof AccountDeletionUserMutationInProgressError ||
      error instanceof AccountMetadataUserUnavailableError
    ) {
      return false;
    }
    throw error;
  }
}

async function reconcileFreshProMetadata(
  user: ProReconcileUser,
  activePlan: PersonalPlanId | null,
  lease: AccountDeletionUserMutationLease,
): Promise<boolean> {
  const metadata = proMetadataRecord(user.clientReadOnlyMetadata);
  if (
    metadata.cmuxAccountDeleting === true ||
    !proMirrorNeedsReconcile(activePlan, planIdFromMetadata(metadata))
  ) {
    return false;
  }
  await syncProPlanMetadata(user, activePlan !== null, lease, activePlan ?? PRO_PLAN_ID);
  return true;
}

/**
 * The `cmuxPlan` mirror needs a write when a personal plan is active but the
 * mirror does not name that exact plan (a Max upgrade must replace "pro"),
 * or when nothing is active but the mirror still names a paid plan (a stale
 * "pro", "max", "team", or "founders" value would keep VM access alive).
 */
function proMirrorNeedsReconcile(
  activePlan: PersonalPlanId | null,
  mirrorPlanId: string | null,
): boolean {
  return activePlan ? mirrorPlanId !== activePlan : isPaidPlanId(mirrorPlanId);
}

const withDefaultFreshProMetadataUser: FreshProMetadataUserMutation = async (
  userId,
  operation,
) => {
  if (!isStackConfigured()) {
    throw new Error("Stack Auth is required for account metadata mutation");
  }
  const app = getStackServerApp();
  type FreshStackProMetadataUser = ProReconcileUser & {
    readonly id: string;
  };
  const loader: AccountMetadataUserLoader<FreshStackProMetadataUser> = {
    getUser: (requestedUserId) => app.getUser(requestedUserId),
  };
  return await withFreshAccountMetadataUser({
    db: cloudDb(),
    userId,
    loader,
    operation: async (freshUser, lease) =>
      await operation(freshUser, lease),
  });
};

/** True when any personal plan (Pro or Max) is active for the user. */
export async function hasActiveStripeProSubscription(
  stackUserId: string,
): Promise<boolean> {
  return (await activePersonalPlanForUser(stackUserId)) !== null;
}

/**
 * The best active personal plan for the user: max when any active row is
 * Max, else pro when any active row is Pro, else null. Rows are labelled by
 * their Price at webhook time, so a portal upgrade shows up here as soon as
 * the subscription.updated event lands.
 */
export async function activePersonalPlanForUser(
  stackUserId: string,
): Promise<PersonalPlanId | null> {
  try {
    const rows = await cloudDb()
      .select({ plan: stripeSubscriptions.plan, id: stripeSubscriptions.id, raw: stripeSubscriptions.raw })
      .from(stripeSubscriptions)
      .where(
        and(
          eq(stripeSubscriptions.stackUserId, stackUserId),
          isNull(stripeSubscriptions.stackTeamId),
          eq(stripeSubscriptions.scope, "user"),
          inArray(stripeSubscriptions.plan, PERSONAL_PLAN_IDS),
          inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
        ),
      );
    return highestPersonalPlanId(rows.filter((row) => !isFounderSubscriptionRow(row)).map((row) => row.plan));
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return null;
    throw error;
  }
}

/** Return whether a personal Stripe customer exists, even when its
 * subscription is canceled or unpaid. */
export async function hasStripeCustomerForUser(stackUserId: string): Promise<boolean> {
  try {
    const rows = await cloudDb()
      .select({ id: stripeCustomers.id })
      .from(stripeCustomers)
      .where(
        and(
          eq(stripeCustomers.stackUserId, stackUserId),
          isNull(stripeCustomers.stackTeamId),
        ),
      )
      .limit(1);
    return rows.length > 0;
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return false;
    throw error;
  }
}

/**
 * Reads the personal Stripe customer and newest Pro subscription in one state
 * snapshot. A customer row is retained for checkout identity, while the
 * newest subscription supplies portal/recovery metadata.
 */
export async function stripeBillingStatusForUser(
  stackUserId: string,
): Promise<StripeBillingStatus> {
  try {
    const db = cloudDb();
    const customerRowsPromise = db
      .select({ id: stripeCustomers.id })
      .from(stripeCustomers)
      .where(
        and(
          eq(stripeCustomers.stackUserId, stackUserId),
          isNull(stripeCustomers.stackTeamId),
        ),
      )
      .limit(1);
    const subscriptionQuery = db
      .select({
        id: stripeSubscriptions.id,
        status: stripeSubscriptions.status,
        plan: stripeSubscriptions.plan,
        raw: stripeSubscriptions.raw,
        cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
        currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
        updatedAt: stripeSubscriptions.updatedAt,
      })
      .from(stripeSubscriptions)
      .where(
        and(
          eq(stripeSubscriptions.stackUserId, stackUserId),
          isNull(stripeSubscriptions.stackTeamId),
          eq(stripeSubscriptions.scope, "user"),
          inArray(stripeSubscriptions.plan, PERSONAL_PLAN_IDS),
          sql`coalesce(${stripeSubscriptions.raw}->'metadata'->>'founders_edition', '') <> 'true'`,
        ),
      );
    const orderedSubscriptionQuery = typeof subscriptionQuery.orderBy === "function"
      ? subscriptionQuery.orderBy(
          desc(sql`${stripeSubscriptions.status} in ('active', 'trialing')`),
          desc(sql`${stripeSubscriptions.plan} = 'max'`),
          desc(stripeSubscriptions.updatedAt),
          desc(stripeSubscriptions.currentPeriodEnd),
        )
      : subscriptionQuery;
    // Active access must come from ANY currently active row, not the newest
    // row: historical rows mean a newer canceled record can hide an older
    // active subscription, which would re-sell Pro to a paying customer. The
    // newest row still supplies portal/recovery metadata.
    const [customerRows, subscriptionRows, activePlanId] = await Promise.all([
      customerRowsPromise,
      orderedSubscriptionQuery.limit(10),
      activePersonalPlanForUser(stackUserId),
    ]);
    const recurringRows = subscriptionRows.filter((row) => !isFounderSubscriptionRow(row));
    const subscription = recurringRows.find((row) =>
      row.plan === activePlanId && (ACTIVE_STRIPE_PRO_STATUSES as readonly string[]).includes(row.status)
    ) ?? pickPortalMetadataRow(recurringRows);
    return { ...stripeBillingStatusFromRows(
      customerRows[0]?.id ?? null,
      subscription,
      activePlanId !== null,
      activePlanId,
    ), subscriptionStatus: subscription?.status ?? null,
    hasRecurringSubscription: recurringRows.some((row) =>
      (ACTIVE_STRIPE_PRO_STATUSES as readonly string[]).includes(row.status)
    ) };
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return emptyStripeBillingStatus();
    throw error;
  }
}

/** Return whether a billing team's Stripe customer exists. */
export async function hasStripeCustomerForTeam(stackTeamId: string): Promise<boolean> {
  try {
    const rows = await cloudDb()
      .select({ id: stripeCustomers.id })
      .from(stripeCustomers)
      .where(eq(stripeCustomers.stackTeamId, stackTeamId))
      .limit(1);
    return rows.length > 0;
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return false;
    throw error;
  }
}

/** Reads a billing team's Stripe customer and newest Team subscription. */
export async function stripeBillingStatusForTeam(
  stackTeamId: string,
): Promise<StripeBillingStatus> {
  try {
    const db = cloudDb();
    const customerRowsPromise = db
      .select({ id: stripeCustomers.id })
      .from(stripeCustomers)
      .where(eq(stripeCustomers.stackTeamId, stackTeamId))
      .limit(1);
    const subscriptionQuery = db
      .select({
        id: stripeSubscriptions.id,
        status: stripeSubscriptions.status,
        cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
        currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
        updatedAt: stripeSubscriptions.updatedAt,
      })
      .from(stripeSubscriptions)
      .where(
        and(
          eq(stripeSubscriptions.stackTeamId, stackTeamId),
          eq(stripeSubscriptions.scope, "team"),
          eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
        ),
      );
    const orderedSubscriptionQuery = typeof subscriptionQuery.orderBy === "function"
      ? subscriptionQuery.orderBy(
          desc(stripeSubscriptions.updatedAt),
          desc(stripeSubscriptions.currentPeriodEnd),
        )
      : subscriptionQuery;
    const [customerRows, subscriptionRows, hasActiveSubscription] = await Promise.all([
      customerRowsPromise,
      orderedSubscriptionQuery.limit(10),
      hasActiveTeamSubscriptionForTeam(stackTeamId),
    ]);
    const subscription = pickPortalMetadataRow(subscriptionRows);
    return stripeBillingStatusFromRows(
      customerRows[0]?.id ?? null,
      subscription,
      hasActiveSubscription,
    );
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return emptyStripeBillingStatus();
    throw error;
  }
}

/** Return whether a durable Founder-marked personal row is still present. */
export async function hasActiveFounderStripeSubscription(
  stackUserId: string,
): Promise<boolean> {
  try {
    return (await activeStripeSubscriptionState(stackUserId)).founder;
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return false;
    throw error;
  }
}

async function activeStripeSubscriptionState(
  stackUserId: string,
): Promise<{ readonly regular: boolean; readonly founder: boolean }> {
  try {
    const rows = await cloudDb()
      .select({
        regular: sql<boolean>`coalesce(bool_or(${stripeSubscriptions.raw}->'metadata'->>'founders_edition' is distinct from 'true'), false)`,
        founder: sql<boolean>`coalesce(bool_or(${stripeSubscriptions.raw}->'metadata'->>'founders_edition' = 'true'), false)`,
      })
      .from(stripeSubscriptions)
      .where(
        and(
          eq(stripeSubscriptions.stackUserId, stackUserId),
          isNull(stripeSubscriptions.stackTeamId),
          eq(stripeSubscriptions.scope, "user"),
          inArray(stripeSubscriptions.plan, PERSONAL_PLAN_IDS),
          inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
        ),
      )
      .limit(1);
    const aggregate = rows[0] as
      | { regular?: unknown; founder?: unknown }
      | undefined;
    if (
      aggregate &&
      ("regular" in aggregate || "founder" in aggregate)
    ) {
      return {
        regular: aggregate.regular === true,
        founder: aggregate.founder === true,
      };
    }
    // Lightweight test doubles and older adapters may return raw rows instead
    // of the aggregate projection. Keep that fallback bounded by the adapter;
    // production PostgreSQL always returns the single aggregate row above.
    const rawRows = rows as unknown as readonly { raw?: unknown }[];
    return {
      regular: rawRows.some((row) => !isFounderSubscriptionRaw(row.raw)),
      founder: rawRows.some((row) => isFounderSubscriptionRaw(row.raw)),
    };
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return { regular: false, founder: false };
    throw error;
  }
}

export async function hasActiveTeamSubscriptionForTeam(
  stackTeamId: string,
): Promise<boolean> {
  try {
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
      .limit(1);
    return rows.length > 0;
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return false;
    throw error;
  }
}

/**
 * A hosted coderouter seat is covered either by the user's own Pro
 * subscription or by the selected team's Team subscription. Keep this as one
 * indexed query so route-session issuance does not serialize two RDS reads.
 * The caller must establish membership in `stackTeamId` before calling.
 */
export async function hasActiveCoderouterSubscription(
  stackUserId: string,
  stackTeamId: string,
  userBillingPlanId?: string | null,
  userHasManualVmPlanOverride = false,
): Promise<boolean> {
  // Auth already resolved this Stack user's authoritative personal plan. Keep
  // the hosted CodeRouter gate on the same Founder-aware source as billing and
  // VM/TestFlight access, including operator grants with no Stripe row.
  // A Founder id is sufficient only when it came from the explicit operator
  // override. A bare `cmuxPlan: "founders"` mirror must still be backed by a
  // durable Founder row, just like any other mirrored plan value.
  if (isFounderPlanId(userBillingPlanId) && userHasManualVmPlanOverride) return true;
  try {
    const rows = await cloudDb()
      .select({
        regular: sql<boolean>`coalesce(bool_or(
          ${stripeSubscriptions.scope} = 'team' or
          (${stripeSubscriptions.scope} = 'user' and
            ${stripeSubscriptions.raw}->'metadata'->>'founders_edition' is distinct from 'true')
        ), false)`,
        founder: sql<boolean>`coalesce(bool_or(
          ${stripeSubscriptions.scope} = 'user' and
          ${stripeSubscriptions.raw}->'metadata'->>'founders_edition' = 'true'
        ), false)`,
      })
      .from(stripeSubscriptions)
      .where(
        and(
          inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
          or(
            and(
              eq(stripeSubscriptions.stackUserId, stackUserId),
              eq(stripeSubscriptions.scope, "user"),
              inArray(stripeSubscriptions.plan, PERSONAL_PLAN_IDS),
            ),
            and(
              eq(stripeSubscriptions.stackTeamId, stackTeamId),
              eq(stripeSubscriptions.scope, "team"),
              eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
            ),
          ),
        ),
      )
      .limit(1);
    const aggregate = rows[0] as
      | { regular?: unknown; founder?: unknown }
      | undefined;
    if (aggregate && ("regular" in aggregate || "founder" in aggregate)) {
      if (aggregate.regular === true) return true;
      return hasCoderouterFounderEntitlement(
        userBillingPlanId,
        userHasManualVmPlanOverride,
        aggregate.founder === true,
      );
    }
    // Lightweight test doubles and older adapters may return raw rows instead
    // of the aggregate projection. Keep this fallback bounded by the adapter.
    const rawRows = rows as unknown as readonly { raw?: unknown }[];
    const regular = rawRows.some((row) => !isFounderSubscriptionRaw(row.raw));
    if (regular) return true;
    const founder = rawRows.some((row) => isFounderSubscriptionRaw(row.raw));
    return hasCoderouterFounderEntitlement(
      userBillingPlanId,
      userHasManualVmPlanOverride,
      founder,
    );
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return false;
    throw error;
  }
}

function hasCoderouterFounderEntitlement(
  userBillingPlanId: string | null | undefined,
  userHasManualVmPlanOverride: boolean,
  hasActiveFounderSubscription: boolean,
): boolean {
  const metadata = userHasManualVmPlanOverride
    ? { cmuxVmPlan: userBillingPlanId }
    : { cmuxPlan: userBillingPlanId };
  return hasEffectiveFounderEntitlement(metadata, hasActiveFounderSubscription);
}

/** Read the same personal Pro entitlement as billing, without metadata writes
 * or treating selected-team membership as a personal operator grant. */
export async function isTestflightEligible(
  user: ProReconcileUser,
  options: {
    hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery;
    hasActiveFounderSubscription?: ActiveFounderSubscriptionQuery;
  } = {},
): Promise<boolean> {
  if (!user.id) return false;
  const metadata = proMetadataRecord(user.clientReadOnlyMetadata);
  if (normalizePersonalPlan(metadata, false).isPro) return true;
  if (options.hasActiveStripeSubscription) {
    const regular = await options.hasActiveStripeSubscription(user.id);
    const founder = !regular && !hasManualVmOverride(metadata) && options.hasActiveFounderSubscription
      ? await options.hasActiveFounderSubscription(user.id)
      : false;
    return normalizePersonalPlan(metadata, regular, founder).isPro;
  }
  const state = await activeStripeSubscriptionState(user.id);
  return normalizePersonalPlan(metadata, state.regular, state.founder).isPro;
}

export function metadataPlanId(raw: unknown): string | null {
  return planIdFromMetadata(proMetadataRecord(raw));
}

/**
 * Writes `cmuxPlan: "team"` and `cmuxSeats` (the subscription quantity) into
 * a Stack team's clientReadOnlyMetadata while a Stripe Team subscription is
 * active; both are removed when it lapses. Seats size the team's Cloud VM
 * allowance (50 machines per seat), so a quantity change must land here even
 * when the plan id is unchanged. `cmuxVmPlan` is operator-owned and left
 * untouched.
 */
export async function syncTeamPlanMetadata(
  team: ProMetadataCustomer,
  isTeam: boolean,
  seats: number | null = null,
): Promise<void> {
  const raw = team.clientReadOnlyMetadata;
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  const currentPlan = metadata.cmuxPlan;
  const currentSeats = metadata.cmuxSeats;

  if (isTeam) {
    const nextSeats = seats !== null && Number.isSafeInteger(seats) && seats > 0 ? seats : null;
    if (currentPlan === TEAM_PLAN_ID && currentSeats === (nextSeats ?? undefined)) return;
    metadata.cmuxPlan = TEAM_PLAN_ID;
    if (nextSeats === null) delete metadata.cmuxSeats;
    else metadata.cmuxSeats = nextSeats;
  } else {
    if (currentPlan !== TEAM_PLAN_ID && currentSeats === undefined) return;
    if (currentPlan === TEAM_PLAN_ID) delete metadata.cmuxPlan;
    delete metadata.cmuxSeats;
  }
  await team.update({ clientReadOnlyMetadata: metadata as ProMetadataJson });
}

function proMetadataRecord(raw: unknown): Record<string, unknown> {
  return raw && typeof raw === "object" && !Array.isArray(raw)
    ? (raw as Record<string, unknown>)
    : {};
}

function hasManualVmOverride(metadata: Record<string, unknown>): boolean {
  return manualVmPlanOverride(metadata) !== null;
}

/** The operator-owned `cmuxVmPlan` override, normalized, or null when unset. */
export function manualVmPlanOverride(raw: unknown): string | null {
  const override = proMetadataRecord(raw).cmuxVmPlan;
  if (typeof override !== "string") return null;
  const normalized = override.trim().toLowerCase();
  return normalized.length > 0 ? normalized : null;
}

/** True for plan ids that grant Pro access (pro, max, team, founders). */
export function isPaidPlanId(planId: string | null | undefined): boolean {
  if (typeof planId !== "string") return false;
  return (PAID_PLAN_IDS as readonly string[]).includes(planId.trim().toLowerCase());
}

function planIdFromMetadata(metadata: Record<string, unknown>): string | null {
  const value = metadata.cmuxPlan;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

export function isFounderSubscriptionRaw(raw: unknown): boolean {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return false;
  const metadata = (raw as Record<string, unknown>).metadata;
  return Boolean(
    metadata &&
      typeof metadata === "object" &&
      !Array.isArray(metadata) &&
      (metadata as Record<string, unknown>).founders_edition === "true",
  );
}

function normalizedPlanValue(value: unknown): string | null {
  return typeof value === "string" && value.trim()
    ? value.trim().toLowerCase()
    : null;
}

function isMissingDatabaseConfig(error: unknown): boolean {
  return error instanceof Error && /DATABASE_URL is required/.test(error.message);
}

/**
 * Pick the subscription row that should drive portal/recovery metadata. A
 * stale canceled row can be newer than a recoverable one, so prefer any
 * recoverable row and sort by its current period end.
 */
function pickPortalMetadataRow<T extends {
  readonly status?: string | null;
  readonly cancelAtPeriodEnd?: boolean | null;
  readonly currentPeriodEnd?: Date | null;
}>(rows: readonly T[]): T | undefined {
  const recoverable = rows.filter((row) =>
    (row.status && (STRIPE_PORTAL_RECOVERABLE_STATUSES as readonly string[]).includes(row.status)) ||
    Boolean(row.cancelAtPeriodEnd));
  if (recoverable.length === 0) return rows[0];
  return [...recoverable].sort((left, right) =>
    (right.currentPeriodEnd?.getTime() ?? 0) -
    (left.currentPeriodEnd?.getTime() ?? 0))[0];
}

function stripeBillingStatusFromRows(
  customerId: string | null,
  subscription: {
    readonly id?: string | null;
    readonly status?: string | null;
    readonly cancelAtPeriodEnd?: boolean | null;
  } | undefined,
  activeSubscriptionOverride?: boolean,
  activePlanId: PersonalPlanId | null = null,
): StripeBillingStatus {
  const subscriptionStatus = subscription?.status ??
    (activeSubscriptionOverride ? "active" : null);
  return {
    customerId,
    subscriptionStatus,
    subscriptionId: subscription?.id ?? null,
    activePlanId,
    cancelAtPeriodEnd: Boolean(subscription?.cancelAtPeriodEnd),
    hasCustomer: customerId !== null,
    hasActiveSubscription: activeSubscriptionOverride ?? (
      subscriptionStatus !== null &&
      (ACTIVE_STRIPE_PRO_STATUSES as readonly string[]).includes(subscriptionStatus)
    ),
  };
}

function emptyStripeBillingStatus(): StripeBillingStatus {
  return {
    customerId: null,
    subscriptionStatus: null,
    subscriptionId: null,
    activePlanId: null,
    cancelAtPeriodEnd: false,
    hasCustomer: false,
    hasActiveSubscription: false,
  };
}
