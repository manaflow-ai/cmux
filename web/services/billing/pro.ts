// cmux Pro subscription helpers.
//
// The `pro` product (user-scoped, product line `cmux-pro`) lives in the Stack
// Auth project config, not in this repo. Prices: yearly $240 (listed first so
// the hosted purchase page pre-selects it) and monthly $30.
//
// VM entitlements (services/vms/auth.ts) read the plan id from the user's
// `clientReadOnlyMetadata.cmuxPlan`, so syncing that key after a verified
// purchase is what upgrades Cloud VM limits — no VM code changes needed.
// `cmuxVmPlan` takes precedence over `cmuxPlan` there and is left untouched
// here so manual overrides survive.

import { inArray, eq, and } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { stripeSubscriptions } from "../../db/schema";

export const PRO_PRODUCT_ID = "pro";
export const TEAM_PRODUCT_ID = process.env.CMUX_TEAM_PRODUCT_ID?.trim() || "team";
export const PRO_PLAN_ID = "pro";
export const TEAM_PLAN_ID = "team";
export const FREE_PLAN_ID = "free";
export const PRO_ACCESS_ITEM_ID = "cmux-pro-access";
export const ACTIVE_STRIPE_PRO_STATUSES = ["active", "trialing", "past_due"] as const;

const PRODUCTS_PAGE_LIMIT = 50;
const MAX_PRODUCT_PAGES = 10;

type CustomerProductLike = {
  readonly id: string | null;
  readonly quantity: number;
  readonly subscription: null | {
    readonly cancelAtPeriodEnd: boolean;
    readonly currentPeriodEnd: Date | null;
  };
};

type ProductsPage = readonly CustomerProductLike[] & {
  readonly nextCursor: string | null;
};

export type ProductsCustomer = {
  listProducts(options?: {
    cursor?: string;
    limit?: number;
  }): Promise<ProductsPage>;
};

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
 * True when the customer owns the `pro` product, either through an active
 * subscription (including one set to cancel at period end — access lasts
 * until the period actually ends) or a manual `grantProduct` comp
 * (subscription null, quantity > 0).
 */
export async function hasActiveProSubscription(
  customer: ProductsCustomer,
): Promise<boolean> {
  let cursor: string | undefined;
  for (let page = 0; page < MAX_PRODUCT_PAGES; page++) {
    const products = await customer.listProducts({
      cursor,
      limit: PRODUCTS_PAGE_LIMIT,
    });
    for (const product of products) {
      if (product.id !== PRO_PRODUCT_ID) continue;
      if (product.subscription !== null) {
        const end = product.subscription.currentPeriodEnd;
        if (!end || end.getTime() > Date.now()) return true;
        continue;
      }
      if (product.quantity > 0) return true;
    }
    if (!products.nextCursor) return false;
    cursor = products.nextCursor;
  }
  return false;
}

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

export type ProReconcileUser = ProductsCustomer & ProMetadataCustomer & {
  readonly id?: string;
};

export type ActiveStripeSubscriptionQuery = (stackUserId: string) => Promise<boolean>;
export type BillingManagementKind = "stripe" | "external" | "none";

type BillingTeamUserLike = {
  readonly selectedTeam?: unknown;
  readonly listTeams?: () => Promise<readonly unknown[]>;
};

type BillingTeamLike = {
  readonly id?: string;
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
 * Read-time reconciliation: compares the `cmuxPlan` metadata against the
 * actual Pro subscription state and syncs it in either direction (upgrade
 * that never hit /api/billing/confirm, or a lapse the user never revisited
 * billing to observe). Skipped when a manual `cmuxVmPlan` override is set —
 * that key wins in plan resolution and is operator-owned. Returns true when
 * metadata was changed.
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

  const isPro = await hasAnyActiveProSubscription(user, options.hasActiveStripeSubscription);
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
  const subscriptionState = await activeProSubscriptionState(
    user,
    options.hasActiveStripeSubscription,
  );
  const isPro = subscriptionState.stackActive || subscriptionState.stripeActive;
  let metadataChanged = false;

  if (!hasManualVmPlanOverride && isPro !== (metadataPlanId === PRO_PLAN_ID)) {
    await syncProPlanMetadata(user, isPro);
    metadataChanged = true;
  }

  return {
    planId: isPro ? PRO_PLAN_ID : FREE_PLAN_ID,
    isPro,
    billingManagement: subscriptionState.stripeActive
      ? "stripe"
      : isPro
        ? "external"
        : "none",
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
  const team = await billingTeamForUser(user);
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

async function hasAnyActiveProSubscription(
  user: ProReconcileUser,
  hasActiveStripeSubscription: ActiveStripeSubscriptionQuery = hasActiveStripeProSubscription,
): Promise<boolean> {
  const state = await activeProSubscriptionState(user, hasActiveStripeSubscription);
  return state.stackActive || state.stripeActive;
}

async function activeProSubscriptionState(
  user: ProReconcileUser,
  hasActiveStripeSubscription: ActiveStripeSubscriptionQuery = hasActiveStripeProSubscription,
): Promise<{ stackActive: boolean; stripeActive: boolean }> {
  const stackActive =
    typeof user.listProducts === "function"
      ? await hasActiveProSubscription(user)
      : false;
  const stripeActive = user.id ? await hasActiveStripeSubscription(user.id) : false;
  return { stackActive, stripeActive };
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

async function billingTeamForUser(user: BillingTeamUserLike): Promise<BillingTeamLike | null> {
  const selected = teamFromUnknown(user.selectedTeam);
  if (selected) return selected;
  const teams = typeof user.listTeams === "function"
    ? (await user.listTeams()).map(teamFromUnknown).filter((team): team is BillingTeamLike => !!team)
    : [];
  return teams.length === 1 ? teams[0] : null;
}

function teamFromUnknown(value: unknown): BillingTeamLike | null {
  if (!value || typeof value !== "object") return null;
  const id = (value as { id?: unknown }).id;
  return typeof id === "string" && id ? { id } : null;
}

function isMissingDatabaseConfig(error: unknown): boolean {
  return error instanceof Error && /DATABASE_URL is required/.test(error.message);
}
