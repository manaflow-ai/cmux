// cmux Pro subscription helpers.
//
// VM entitlements (services/vms/auth.ts) read the plan id from the user's
// `clientReadOnlyMetadata.cmuxPlan`, so syncing that key after a verified
// purchase is what upgrades Cloud VM limits — no VM code changes needed.
// `cmuxVmPlan` takes precedence over `cmuxPlan` there and is left untouched
// here so manual overrides survive.

import { and, desc, eq, inArray, isNull, or } from "drizzle-orm";

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
export const TEAM_PLAN_ID = "team";
// Founder's Edition is a one-time purchase. Its completion recorder stores a
// durable active Pro row with a Founder marker, and subscription reconciliation
// skips that marker so a cancelled provider duplicate cannot clear access.
// Existing operator grants may still use `cmuxVmPlan: "founders"`.
export const FOUNDERS_PLAN_ID = "founders";
export const FREE_PLAN_ID = "free";
/**
 * Plan ids an operator may write to `clientReadOnlyMetadata.cmuxVmPlan` to
 * grant Pro without a Stripe subscription. Mirrors `isPaidVmPlan` in
 * services/vms/entitlements.ts so the desktop plan and the VM plan agree.
 */
export const PAID_PLAN_IDS = [PRO_PLAN_ID, TEAM_PLAN_ID, FOUNDERS_PLAN_ID] as const;
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
 * Writes `cmuxPlan: "pro"` into the user's clientReadOnlyMetadata when Pro is
 * active, and removes it when Pro lapsed. Returns the normalized metadata
 * snapshot that was written or observed.
 */
export async function syncProPlanMetadata(
  user: ProMetadataCustomer,
  isPro: boolean,
  lease: AccountDeletionUserMutationLease,
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
    if (current === PRO_PLAN_ID) return metadata as ProMetadataJson;
    metadata.cmuxPlan = PRO_PLAN_ID;
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
};

export type ActiveStripeSubscriptionQuery = (stackUserId: string) => Promise<boolean>;
export type StripeCustomerQuery = (stackUserId: string) => Promise<boolean>;
export type StripeBillingStatus = {
  /** The existing Stripe customer id, when one is recorded for this owner. */
  readonly customerId: string | null;
  /** The newest recorded Pro subscription state, if any. */
  readonly subscriptionStatus: string | null;
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
  readonly planId: typeof FREE_PLAN_ID | typeof PRO_PLAN_ID;
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

  const isPro = user.id
    ? await (options.hasActiveStripeSubscription ?? hasActiveStripeProSubscription)(user.id)
    : false;
  if (!proMirrorNeedsReconcile(isPro, planIdFromMetadata(metadata))) return false;
  if (!user.id) return false;
  return await reconcileProMetadataIfAvailable(
    user.id,
    isPro,
    options.withFreshMetadataUser ?? withDefaultFreshProMetadataUser,
  );
}

export async function resolveProPlanStatus(
  user: ProReconcileUser,
  options: {
    hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery;
    hasStripeCustomer?: StripeCustomerQuery;
    /** Optional state snapshot used by checkout and deterministic callers. */
    stripeBillingStatus?: StripeBillingStatus | StripeBillingStatusQuery;
    withFreshMetadataUser?: FreshProMetadataUserMutation;
  } = {},
): Promise<ProPlanStatus> {
  const metadata = proMetadataRecord(user.clientReadOnlyMetadata);
  const hasManualVmPlanOverride = hasManualVmOverride(metadata);
  const metadataPlanId = planIdFromMetadata(metadata);
  const hasLegacyQueryOverrides = Boolean(
    options.hasActiveStripeSubscription || options.hasStripeCustomer,
  );
  const stripeBillingStatus = user.id
    ? await resolveStripeBillingStatus(
        user.id,
        options.stripeBillingStatus,
        hasLegacyQueryOverrides,
      )
    : null;
  const hasActiveStripePro = user.id
    ? options.hasActiveStripeSubscription
      ? await options.hasActiveStripeSubscription(user.id)
      : stripeBillingStatus
        ? stripeBillingStatus.hasActiveSubscription
        : await hasActiveStripeProSubscription(user.id)
    : false;
  // An operator grant (`cmuxVmPlan` set to a paid plan by the admin dashboard
  // or dev-grant.sh) is Pro everywhere, not only for Cloud VM limits. Billing
  // management below still keys off Stripe state, since a granted account has
  // no subscription for the portal to manage.
  const isPro = hasActiveStripePro || isPaidPlanId(manualVmPlanOverride(metadata));
  // A customer row alone is not enough to open the portal. Stripe cannot start
  // a new subscription from the portal after a terminal cancellation (or when
  // the row has no subscription), so only recoverable subscription states keep
  // billing management enabled.
  const hasStripeCustomer = user.id
    ? options.hasStripeCustomer
      ? await options.hasStripeCustomer(user.id)
      : stripeBillingStatus?.hasCustomer ?? (hasActiveStripePro && !stripeBillingStatus)
    : false;
  const billingManagement: BillingManagementKind = stripeBillingStatus
    ? hasActiveStripePro || isStripePortalRecoverable(stripeBillingStatus)
      ? "stripe"
      : "none"
    : hasActiveStripePro || hasStripeCustomer
      ? "stripe"
      : "none";
  let metadataChanged = false;

  if (
    user.id &&
    !hasManualVmPlanOverride &&
    proMirrorNeedsReconcile(hasActiveStripePro, metadataPlanId)
  ) {
    metadataChanged = await reconcileProMetadataIfAvailable(
      user.id,
      hasActiveStripePro,
      options.withFreshMetadataUser ?? withDefaultFreshProMetadataUser,
    );
  }

  return {
    planId: isPro ? PRO_PLAN_ID : FREE_PLAN_ID,
    isPro,
    billingManagement,
    metadataPlanId,
    hasManualVmPlanOverride,
    metadataChanged,
  };
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
  isPro: boolean,
  withFreshMetadataUser: FreshProMetadataUserMutation,
): Promise<boolean> {
  try {
    return await withFreshMetadataUser(
      userId,
      (freshUser, lease) => reconcileFreshProMetadata(freshUser, isPro, lease),
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
  isPro: boolean,
  lease: AccountDeletionUserMutationLease,
): Promise<boolean> {
  const metadata = proMetadataRecord(user.clientReadOnlyMetadata);
  if (
    metadata.cmuxAccountDeleting === true ||
    hasManualVmOverride(metadata) ||
    !proMirrorNeedsReconcile(isPro, planIdFromMetadata(metadata))
  ) {
    return false;
  }
  await syncProPlanMetadata(user, isPro, lease);
  return true;
}

/**
 * The `cmuxPlan` mirror needs a write when Pro is active but the mirror is
 * not "pro", or when Pro is inactive but the mirror still names a paid plan
 * (a stale "pro", "team", or "founders" value would keep VM access alive).
 */
function proMirrorNeedsReconcile(isPro: boolean, mirrorPlanId: string | null): boolean {
  return isPro ? mirrorPlanId !== PRO_PLAN_ID : isPaidPlanId(mirrorPlanId);
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

export async function hasActiveStripeProSubscription(
  stackUserId: string,
): Promise<boolean> {
  try {
    const rows = await cloudDb()
      .select({ id: stripeSubscriptions.id })
      .from(stripeSubscriptions)
      .where(
        and(
          eq(stripeSubscriptions.stackUserId, stackUserId),
          isNull(stripeSubscriptions.stackTeamId),
          eq(stripeSubscriptions.scope, "user"),
          eq(stripeSubscriptions.plan, PRO_PLAN_ID),
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
        status: stripeSubscriptions.status,
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
          eq(stripeSubscriptions.plan, PRO_PLAN_ID),
        ),
      );
    // Keep the ordering in the real Drizzle query, while allowing lightweight
    // database doubles that expose only the common where/limit chain.
    const orderedSubscriptionQuery = typeof subscriptionQuery.orderBy === "function"
      ? subscriptionQuery.orderBy(
          desc(stripeSubscriptions.updatedAt),
          desc(stripeSubscriptions.currentPeriodEnd),
        )
      : subscriptionQuery;
    // Active access must come from ANY currently active row, not the newest
    // row: historical rows mean a newer canceled record can hide an older
    // active subscription, which would re-sell Pro to a paying customer. The
    // newest row still supplies portal/recovery metadata.
    const [customerRows, subscriptionRows, hasActiveSubscription] = await Promise.all([
      customerRowsPromise,
      orderedSubscriptionQuery.limit(10),
      hasActiveStripeProSubscription(stackUserId),
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

/**
 * A hosted coderouter seat is covered either by the user's own Pro
 * subscription or by the selected team's Team subscription. Keep this as one
 * indexed query so route-session issuance does not serialize two RDS reads.
 * The caller must establish membership in `stackTeamId` before calling.
 */
export async function hasActiveCoderouterSubscription(
  stackUserId: string,
  stackTeamId: string,
): Promise<boolean> {
  try {
    const rows = await cloudDb()
      .select({ id: stripeSubscriptions.id })
      .from(stripeSubscriptions)
      .where(
        and(
          inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
          or(
            and(
              eq(stripeSubscriptions.stackUserId, stackUserId),
              eq(stripeSubscriptions.scope, "user"),
              eq(stripeSubscriptions.plan, PRO_PLAN_ID),
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
    return rows.length > 0;
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return false;
    throw error;
  }
}

export async function isTestflightEligible(
  user: ProReconcileUser,
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

/** True for plan ids that grant Pro access (pro, team, founders). */
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
    readonly status?: string | null;
    readonly cancelAtPeriodEnd?: boolean | null;
  } | undefined,
  activeSubscriptionOverride?: boolean,
): StripeBillingStatus {
  const subscriptionStatus = subscription?.status ??
    (activeSubscriptionOverride ? "active" : null);
  return {
    customerId,
    subscriptionStatus,
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
    cancelAtPeriodEnd: false,
    hasCustomer: false,
    hasActiveSubscription: false,
  };
}
