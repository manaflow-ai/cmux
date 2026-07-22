// cmux Pro subscription helpers.
//
// VM entitlements (services/vms/auth.ts) read the plan id from the user's
// `clientReadOnlyMetadata.cmuxPlan`, so syncing that key after a verified
// purchase is what upgrades Cloud VM limits — no VM code changes needed.
// `cmuxVmPlan` takes precedence over `cmuxPlan` there and is left untouched
// here so manual overrides survive.

import { inArray, eq, and } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";
import { resolveBillingTeam, type BillingTeamUserLike } from "./teamResolution";

export const PRO_PLAN_ID = "pro";
export const TEAM_PLAN_ID = "team";
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
 * active, and removes it when Pro lapsed. No-op when already in sync.
 */
export async function syncProPlanMetadata(
  user: ProMetadataCustomer,
  isPro: boolean,
): Promise<void> {
  const raw = user.clientReadOnlyMetadata;
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  if (metadata.cmuxAccountDeleting === true) return;
  const current = metadata.cmuxPlan;

  if (isPro) {
    if (current === PRO_PLAN_ID) return;
    metadata.cmuxPlan = PRO_PLAN_ID;
  } else {
    if (current !== PRO_PLAN_ID) return;
    delete metadata.cmuxPlan;
  }
  // Existing metadata came from Stack as JSON; the only value added is a string.
  await user.update({ clientReadOnlyMetadata: metadata as ProMetadataJson });
}

export type ProReconcileUser = ProMetadataCustomer & {
  readonly id?: string;
};

export type ActiveStripeSubscriptionQuery = (stackUserId: string) => Promise<boolean>;
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
  options: { hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery } = {},
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
  if (isPro === (metadata.cmuxPlan === PRO_PLAN_ID)) return false;
  await syncProPlanMetadata(user, isPro);
  return true;
}

export async function resolveProPlanStatus(
  user: ProReconcileUser,
  options: { hasActiveStripeSubscription?: ActiveStripeSubscriptionQuery } = {},
): Promise<ProPlanStatus> {
  const metadata = proMetadataRecord(user.clientReadOnlyMetadata);
  const hasManualVmPlanOverride = hasManualVmOverride(metadata);
  const metadataPlanId = planIdFromMetadata(metadata);
  const isPro = user.id
    ? await (options.hasActiveStripeSubscription ?? hasActiveStripeProSubscription)(user.id)
    : false;
  let metadataChanged = false;

  if (!hasManualVmPlanOverride && isPro !== (metadataPlanId === PRO_PLAN_ID)) {
    await syncProPlanMetadata(user, isPro);
    metadataChanged = true;
  }

  return {
    planId: isPro ? PRO_PLAN_ID : FREE_PLAN_ID,
    isPro,
    billingManagement: isPro ? "stripe" : "none",
    metadataPlanId,
    hasManualVmPlanOverride,
    metadataChanged,
  };
}

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
  user: ProReconcileUser & BillingTeamUserLike,
): Promise<boolean> {
  const status = await resolveProPlanStatus(user);
  if (status.isPro) return true;
  const team = await resolveBillingTeam(user);
  return team?.id ? hasActiveTeamSubscriptionForTeam(team.id) : false;
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

function isMissingDatabaseConfig(error: unknown): boolean {
  return error instanceof Error && /DATABASE_URL is required/.test(error.message);
}
