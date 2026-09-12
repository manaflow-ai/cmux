// cmux Pro subscription helpers.
//
// VM entitlements (services/vms/auth.ts) read the plan id from the user's
// `clientReadOnlyMetadata.cmuxPlan`, so syncing that key after a verified
// purchase is what upgrades Cloud VM limits — no VM code changes needed.
// `cmuxVmPlan` takes precedence over `cmuxPlan` there and is left untouched
// here so manual overrides survive.

import { and, desc, eq, inArray, isNull, sql } from "drizzle-orm";

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
// Max is Pro plus the 32 GB and 64 GB machine sizes. It is a personal
// subscription like Pro: same Stripe customer scope, same metadata mirror
// (`cmuxPlan: "max"`), and it satisfies every "is Pro" check.
export const MAX_PLAN_ID = "max";
export const TEAM_PLAN_ID = "team";
// Founder's Edition is a one-time purchase. Its completion recorder stores a
// durable active Pro row with a Founder marker, and subscription reconciliation
// skips that marker so a cancelled provider duplicate cannot clear access.
// Existing operator grants may still use `cmuxVmPlan: "founders"`.
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
export const PAID_PLAN_IDS = [PRO_PLAN_ID, MAX_PLAN_ID, TEAM_PLAN_ID, FOUNDERS_PLAN_ID] as const;
/**
 * Plans a person buys for themselves through `/api/billing/checkout`. A
 * user-scoped Stripe subscription row carries one of these in `plan`, derived
 * from its Price (see `personalPlanIdForPrice` in purchase.ts) so a portal
 * upgrade between them re-labels the row on the next webhook.
 */
export const PERSONAL_PLAN_IDS = [PRO_PLAN_ID, MAX_PLAN_ID] as const;
export type PersonalPlanId = (typeof PERSONAL_PLAN_IDS)[number];
/** Higher index wins when an account has more than one active personal row. */
const PERSONAL_PLAN_RANK: Record<PersonalPlanId, number> = { pro: 1, max: 2 };

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
 * Writes `cmuxPlan: "pro"` (or `"max"`, the plan in force) into the user's
 * clientReadOnlyMetadata when a personal subscription is active, and removes
 * it when it lapsed. Returns the normalized metadata snapshot that was
 * written or observed.
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
  readonly isAnonymous?: boolean;
};

export type ActiveStripeSubscriptionQuery = (stackUserId: string) => Promise<boolean>;
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
export type BillingManagementKind = "stripe" | "none";

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
 * Read-time reconciliation: compares the `cmuxPlan` metadata against the
 * actual Stripe Pro subscription state and syncs it in either direction.
 * Skipped when a manual `cmuxVmPlan` override is set — that key wins in plan
 * resolution and is operator-owned. Returns true when metadata was changed.
 */
export async function reconcileProPlanMetadata(
  user: ProReconcileUser,
  options: {
    hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery;
    activePersonalPlan?: ActivePersonalPlanQuery;
    withFreshMetadataUser?: FreshProMetadataUserMutation;
  } = {},
): Promise<boolean> {
  const raw = user.clientReadOnlyMetadata;
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {};
  const override = metadata.cmuxVmPlan;
  if (typeof override === "string" && override.trim()) return false;

  const activePlan = user.id
    ? await resolveActivePersonalPlan(user.id, options)
    : null;
  if (!proMirrorNeedsReconcile(activePlan, planIdFromMetadata(metadata))) return false;
  if (!user.id) return false;
  return await reconcileProMetadataIfAvailable(
    user.id,
    activePlan,
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
    activePersonalPlan?: ActivePersonalPlanQuery;
    hasStripeCustomer?: StripeCustomerQuery;
    /** Optional state snapshot used by checkout and deterministic callers. */
    stripeBillingStatus?: StripeBillingStatus | StripeBillingStatusQuery;
    withFreshMetadataUser?: FreshProMetadataUserMutation;
    /** Runtime environment override used by deterministic callers and tests. */
    environment?: Record<string, string | undefined>;
  } = {},
): Promise<ProPlanStatus> {
  const metadata = proMetadataRecord(user.clientReadOnlyMetadata);
  const hasManualVmPlanOverride = hasManualVmOverride(metadata);
  const metadataPlanId = planIdFromMetadata(metadata);
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
  const planId = personalPlanIdForStatus(activeStripePlan, manualVmPlanOverride(metadata));
  const isPro = planId !== FREE_PLAN_ID;
  const billingManagement = billingManagementForStatus(
    stripeBillingStatus,
    hasActiveStripePro,
    hasStripeCustomer,
  );
  let metadataChanged = false;

  if (
    user.id &&
    !hasManualVmPlanOverride &&
    proMirrorNeedsReconcile(activeStripePlan, metadataPlanId)
  ) {
    metadataChanged = await reconcileProMetadataIfAvailable(
      user.id,
      activeStripePlan,
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
    hasManualVmOverride(metadata) ||
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
      .select({ plan: stripeSubscriptions.plan })
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
      .limit(PERSONAL_PLAN_IDS.length);
    // The where-clause guarantees a personal plan on every row; a row whose
    // plan is not readable (a partial test double) still proves Pro access.
    return highestPersonalPlanId(rows.map((row) => row.plan)) ??
      (rows.length > 0 ? PRO_PLAN_ID : null);
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
 * Reads the personal Stripe customer and its newest Pro subscription in one
 * state snapshot. A customer row is retained for checkout identity, while the
 * newest subscription decides whether the portal can recover billing.
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
    // Keep the ordering in the real Drizzle query, while allowing lightweight
    // database doubles that expose only the common where/limit chain.
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
    // Same any-active-row authority rule as the personal snapshot.
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

export async function isTestflightEligible(
  user: Pick<ProReconcileUser, "id">,
  options: {
    hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery;
  } = {},
): Promise<boolean> {
  if (!user.id) return false;
  return (options.hasActiveStripeSubscription ?? hasActiveStripeProSubscription)(
    user.id,
  );
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

function isMissingDatabaseConfig(error: unknown): boolean {
  return error instanceof Error && /DATABASE_URL is required/.test(error.message);
}

/**
 * Pick the subscription row that should drive portal/recovery metadata. A
 * stale canceled row can carry the newest updatedAt, so prefer any
 * portal-recoverable row (latest period end wins) and fall back to the first
 * returned row.
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
  return [...recoverable].sort((a, b) =>
    (b.currentPeriodEnd?.getTime() ?? 0) - (a.currentPeriodEnd?.getTime() ?? 0))[0];
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
