// cmux Pro subscription helpers.
//
// VM entitlements (services/vms/auth.ts) read the plan id from the user's
// `clientReadOnlyMetadata.cmuxPlan`, so syncing that key after a verified
// purchase is what upgrades Cloud VM limits — no VM code changes needed.
// `cmuxVmPlan` takes precedence over `cmuxPlan` there and is left untouched
// here so manual overrides survive.

import { inArray, eq, and, or } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
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
// Existing operator grants may still use `cmuxVmPlan: "founders"`; both forms
// provide Pro access without subscription-management controls.
export const FOUNDERS_PLAN_ID = "founders";
export const FREE_PLAN_ID = "free";
export const PRO_ACCESS_ITEM_ID = "cmux-pro-access";
export const ACTIVE_STRIPE_PRO_STATUSES = ["active", "trialing", "past_due"] as const;

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
  // A Founder entitlement is permanent. Keep its marker intact when Stripe
  // lifecycle events reconcile the ordinary `cmuxPlan` key.
  if (hasFounderEditionEntitlement(metadata)) {
    return metadata as ProMetadataJson;
  }
  const current = metadata.cmuxPlan;

  if (isPro) {
    if (current === PRO_PLAN_ID) return metadata as ProMetadataJson;
    metadata.cmuxPlan = PRO_PLAN_ID;
  } else {
    if (current !== PRO_PLAN_ID) return metadata as ProMetadataJson;
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
  readonly planId: typeof FREE_PLAN_ID | typeof PRO_PLAN_ID;
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
  const isFounder =
    hasActiveFounderSubscription || hasFounderEditionEntitlement(metadata);
  const isPro = hasActiveStripeSubscription || isFounder;
  return {
    planId: isPro ? PRO_PLAN_ID : FREE_PLAN_ID,
    isPro,
    billingManagement: hasActiveStripeSubscription ? "stripe" : "none",
  };
}

/** Resolve Founder's Edition only from durable account metadata. */
export function hasFounderEditionEntitlement(raw: unknown): boolean {
  const metadata = proMetadataRecord(raw);
  // `cmuxVmPlan` is authoritative when present; a lower-priority `cmuxPlan`
  // value must not bypass an explicit operator override. The fallback keeps
  // older verified Founder records durable during migration.
  const override = normalizedPlanValue(metadata.cmuxVmPlan);
  const source = override ?? normalizedPlanValue(metadata.cmuxPlan);
  return source === FOUNDERS_PLAN_ID;
}

/**
 * Read-time reconciliation: compares the `cmuxPlan` metadata against the
 * actual Stripe Pro subscription state and syncs it in either direction.
 * Skipped when a manual `cmuxVmPlan` override or Founder marker is set.
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
  if (hasManualVmOverride(metadata) || hasFounderEditionEntitlement(metadata)) {
    return false;
  }

  const isPro = user.id
    ? await (options.hasActiveStripeSubscription ?? hasActiveStripeProSubscription)(user.id)
    : false;
  if (isPro === (metadata.cmuxPlan === PRO_PLAN_ID)) return false;
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
    hasActiveFounderSubscription?: ActiveFounderSubscriptionQuery;
    withFreshMetadataUser?: FreshProMetadataUserMutation;
    claimPendingBilling?: PendingBillingClaimResolver;
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
  let hasActiveStripeSubscription = false;
  let hasActiveFounderSubscription = metadataFounderEntitlement;
  if (user.id) {
    if (options.hasActiveStripeSubscription) {
      hasActiveStripeSubscription = await options.hasActiveStripeSubscription(user.id);
      if (!hasActiveStripeSubscription && options.hasActiveFounderSubscription) {
        hasActiveFounderSubscription ||= await options.hasActiveFounderSubscription(user.id);
      }
    } else {
      // One bounded read classifies both regular and Founder rows, avoiding a
      // second database round trip on every plan request.
      const state = await activeStripeSubscriptionState(user.id);
      hasActiveStripeSubscription = state.regular;
      hasActiveFounderSubscription ||= state.founder;
    }
  }
  const hasManualVmPlanOverride =
    hasManualVmOverride(metadata) || hasActiveFounderSubscription;
  const normalizedPlan = normalizePersonalPlan(
    user.clientReadOnlyMetadata,
    hasActiveStripeSubscription,
    hasActiveFounderSubscription,
  );
  let metadataChanged = false;

  if (
    user.id &&
    !hasManualVmPlanOverride &&
    hasActiveStripeSubscription !== (metadataPlanId === PRO_PLAN_ID)
  ) {
    metadataChanged = await reconcileProMetadataIfAvailable(
      user.id,
      hasActiveStripeSubscription,
      options.withFreshMetadataUser ?? withDefaultFreshProMetadataUser,
    );
  }

  return {
    ...normalizedPlan,
    metadataPlanId,
    hasManualVmPlanOverride,
    metadataChanged,
  };
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
    hasFounderEditionEntitlement(metadata) ||
    isPro === (metadata.cmuxPlan === PRO_PLAN_ID)
  ) {
    return false;
  }
  await syncProPlanMetadata(user, isPro, lease);
  return true;
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
    return (await activeStripeSubscriptionState(stackUserId)).regular;
  } catch (error) {
    if (isMissingDatabaseConfig(error)) return false;
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
      .select({ raw: stripeSubscriptions.raw })
      .from(stripeSubscriptions)
      .where(
        and(
          eq(stripeSubscriptions.stackUserId, stackUserId),
          eq(stripeSubscriptions.scope, "user"),
          eq(stripeSubscriptions.plan, PRO_PLAN_ID),
          inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
        ),
      )
      .limit(100);
    return {
      regular: rows.some((row) => !isFounderSubscriptionRaw(row.raw)),
      founder: rows.some((row) => isFounderSubscriptionRaw(row.raw)),
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
 * Writes `cmuxPlan: "team"` into a Stack team's clientReadOnlyMetadata while a
 * Stripe Team subscription is active. `cmuxVmPlan` is operator-owned and left
 * untouched.
 */
export async function syncTeamPlanMetadata(
  team: ProMetadataCustomer,
  isTeam: boolean,
): Promise<void> {
  const raw = team.clientReadOnlyMetadata;
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  const current = metadata.cmuxPlan;

  if (isTeam) {
    if (current === TEAM_PLAN_ID) return;
    metadata.cmuxPlan = TEAM_PLAN_ID;
  } else {
    if (current !== TEAM_PLAN_ID) return;
    delete metadata.cmuxPlan;
  }
  await team.update({ clientReadOnlyMetadata: metadata as ProMetadataJson });
}

function proMetadataRecord(raw: unknown): Record<string, unknown> {
  return raw && typeof raw === "object" && !Array.isArray(raw)
    ? (raw as Record<string, unknown>)
    : {};
}

function hasManualVmOverride(metadata: Record<string, unknown>): boolean {
  const override = metadata.cmuxVmPlan;
  return typeof override === "string" && override.trim().length > 0;
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
