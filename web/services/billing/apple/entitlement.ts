// Which Apple subscriptions grant a plan right now. pro.ts combines this
// with the Stripe plan, so this module must not import pro.ts at runtime.

import { and, eq, inArray, isNotNull } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import { appleSubscriptions, appleTransactions, type AppleSubscriptionStatus } from "../../../db/schema";
import type { PersonalPlanId } from "../pro";
import { planTierRank } from "../planTier";
import { APP_STORE_BUNDLE_ID, appleEnvironmentGrantsEntitlement, appleSandboxGrantNeedsAccountEmail } from "./config";

/** Personal plans sold in the App Store; the best grant wins by tier. */
const APPLE_PLAN_IDS: ReadonlySet<string> = new Set(["go", "pro", "max"]);

type Env = Record<string, string | undefined>;

export type AppleEntitlementRow = {
  readonly originalTransactionId: string;
  readonly planId: string;
  readonly status: AppleSubscriptionStatus | string;
  readonly environment: string;
  readonly bundleId: string;
  readonly expiresAt: Date | null;
  readonly gracePeriodExpiresAt: Date | null;
  readonly autoRenewEnabled?: boolean | null;
  /** Purchase date of the newest transaction: the start of the current period. */
  readonly purchaseDate?: Date | null;
  /** A paid higher plan kept after an early renewal into a lower one (see `carried_plan_id`). */
  readonly carriedPlanId?: string | null;
  readonly carriedUntil?: Date | null;
  readonly carriedTransactionId?: string | null;
  /** When the carried plan's transaction was refunded; a refunded period carries nothing. */
  readonly carriedRevokedAt?: Date | null;
};

/**
 * The plan a row grants at `now`: its carried plan while that paid period
 * still runs and was not refunded, else its own. Status and expiry are
 * checked separately (appleSubscriptionGrantsAccess).
 */
export function appleEntitlementPlanAt(row: AppleEntitlementRow, now: Date): string {
  const carried = row.carriedPlanId;
  if (!carried || !row.carriedUntil || row.carriedUntil.getTime() <= now.getTime() || row.carriedRevokedAt) {
    return row.planId;
  }
  return planTierRank(carried) > planTierRank(row.planId) ? carried : row.planId;
}


function isAfter(value: Date | null, now: Date): boolean {
  return value !== null && value.getTime() > now.getTime();
}

/**
 * Apple keeps access while a subscription is active and unexpired, and
 * during billing retry only inside the grace period
 * (`gracePeriodExpiresDate`). Expired and revoked (refund, Family Sharing
 * revoke) never grant.
 */
export function appleSubscriptionGrantsAccess(
  row: AppleEntitlementRow,
  now: Date = new Date(),
  env: Env = process.env,
  accountEmail: string | null = null,
): boolean {
  if (!APPLE_PLAN_IDS.has(row.planId)) return false;
  if (!appleEnvironmentGrantsEntitlement({ ...row, accountEmail }, env)) return false;
  return appleStatusGrantsAt(row, now);
}

/**
 * The status and time part of the grant rule alone, without the plan and
 * Sandbox policy: whether Apple's state keeps access at `now`.
 */
export function appleStatusGrantsAt(
  row: Pick<AppleEntitlementRow, "status" | "expiresAt" | "gracePeriodExpiresAt">,
  now: Date,
): boolean {
  switch (row.status) {
    case "active":
      return isAfter(row.expiresAt, now);
    case "grace_period":
      return isAfter(row.gracePeriodExpiresAt ?? row.expiresAt, now);
    case "billing_retry":
      return isAfter(row.gracePeriodExpiresAt, now);
    default:
      return false;
  }
}

/** The granting subscription with the highest plan, or null. */
export function bestAppleEntitlement<Row extends AppleEntitlementRow>(
  rows: readonly Row[],
  now: Date = new Date(),
  env: Env = process.env,
  accountEmail: string | null = null,
): Row | null {
  let best: Row | null = null;
  for (const row of rows) {
    if (!appleSubscriptionGrantsAccess(row, now, env, accountEmail)) continue;
    if (!best || planTierRank(row.planId) > planTierRank(best.planId)) best = row;
  }
  return best;
}

export async function appleSubscriptionRowsForUser(userId: string): Promise<AppleEntitlementRow[]> {
  return await cloudDb()
    .select({
      originalTransactionId: appleSubscriptions.originalTransactionId,
      planId: appleSubscriptions.planId,
      status: appleSubscriptions.status,
      environment: appleSubscriptions.environment,
      bundleId: appleSubscriptions.bundleId,
      expiresAt: appleSubscriptions.expiresAt,
      gracePeriodExpiresAt: appleSubscriptions.gracePeriodExpiresAt,
      autoRenewEnabled: appleSubscriptions.autoRenewEnabled,
      purchaseDate: appleSubscriptions.purchaseDate,
      carriedPlanId: appleSubscriptions.carriedPlanId,
      carriedUntil: appleSubscriptions.carriedUntil,
      carriedTransactionId: appleSubscriptions.carriedTransactionId,
    })
    .from(appleSubscriptions)
    .where(eq(appleSubscriptions.userId, userId));
}

/**
 * Marks carried plans whose transaction was refunded. Only rows with a carry
 * still running need it, so a plan read stays one query in the usual case.
 */
async function withCarriedRefunds(
  rows: readonly AppleEntitlementRow[],
  now: Date,
): Promise<AppleEntitlementRow[]> {
  const carried = rows
    .filter((row) => row.carriedTransactionId && row.carriedUntil && row.carriedUntil.getTime() > now.getTime())
    .map((row) => row.carriedTransactionId!);
  if (carried.length === 0) return [...rows];
  const refunded = await cloudDb()
    .select({ transactionId: appleTransactions.transactionId, revokedAt: appleTransactions.revokedAt })
    .from(appleTransactions)
    .where(and(inArray(appleTransactions.transactionId, carried), isNotNull(appleTransactions.revokedAt)));
  const revokedAt = new Map(refunded.map((row) => [row.transactionId, row.revokedAt]));
  return rows.map((row) => row.carriedTransactionId && revokedAt.has(row.carriedTransactionId)
    ? { ...row, carriedRevokedAt: revokedAt.get(row.carriedTransactionId) ?? null }
    : row);
}

/**
 * The account's verified primary email, read only when a production Sandbox
 * row needs the allowlist. An unverified address could be anyone's, so it
 * never matches. Stack is the source of truth; a failed read throws so a
 * transient outage never downgrades an allowlisted tester's plan mirror.
 */
async function stackPrimaryEmail(userId: string): Promise<string | null> {
  const { getStackServerApp, isStackConfigured } = await import("../../../app/lib/stack");
  if (!isStackConfigured()) return null;
  const user = await getStackServerApp().getUser(userId);
  return user?.primaryEmailVerified ? user.primaryEmail ?? null : null;
}

export type AppleEntitlementLookupOptions = {
  readonly now?: Date;
  readonly env?: Env;
  /** Defaults to the Stack account's primary email. */
  readonly accountEmail?: (userId: string) => Promise<string | null>;
};

/**
 * The user's granting Apple subscription (highest plan), or null. A
 * deployment without a database grants nothing, like the Stripe query.
 */
export async function activeAppleEntitlementForUser(
  userId: string,
  options: AppleEntitlementLookupOptions | Date = {},
): Promise<AppleEntitlementRow | null> {
  const { now = new Date(), env = process.env, accountEmail = stackPrimaryEmail } =
    options instanceof Date ? { now: options } : options;
  let rows: AppleEntitlementRow[];
  try {
    rows = await appleSubscriptionRowsForUser(userId);
  } catch (error) {
    if (error instanceof Error && /DATABASE_URL is required/.test(error.message)) return null;
    throw error;
  }
  // Lightweight database doubles in older tests may return non-array values.
  if (!Array.isArray(rows)) return null;
  rows = (await withCarriedRefunds(rows, now)).map((row) => ({ ...row, planId: appleEntitlementPlanAt(row, now) }));
  const needsEmail = appleSandboxGrantNeedsAccountEmail(env) &&
    rows.some((row) => row.environment === "Sandbox" && row.bundleId === APP_STORE_BUNDLE_ID &&
      appleSubscriptionGrantsAccess(row, now, {}));
  const email = needsEmail ? await accountEmail(userId) : null;
  return bestAppleEntitlement(rows, now, env, email);
}

export async function activeApplePlanForUser(userId: string): Promise<PersonalPlanId | null> {
  const row = await activeAppleEntitlementForUser(userId);
  return row ? row.planId as PersonalPlanId : null;
}
