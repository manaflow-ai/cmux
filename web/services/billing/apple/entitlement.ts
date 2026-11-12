// Which Apple subscriptions grant a plan right now. pro.ts combines this
// with the Stripe plan, so this module must not import pro.ts at runtime.

import { eq } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import { appleSubscriptions, type AppleSubscriptionStatus } from "../../../db/schema";
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
};


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
    })
    .from(appleSubscriptions)
    .where(eq(appleSubscriptions.userId, userId));
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
