// Which Apple subscriptions grant a plan right now. pro.ts combines this
// with the Stripe plan, so this module must not import pro.ts at runtime.

import { eq } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import { appleSubscriptions, type AppleSubscriptionStatus } from "../../../db/schema";
import type { PersonalPlanId } from "../pro";
import { appleEnvironmentGrantsEntitlement } from "./config";

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
};

const PLAN_RANK: Readonly<Record<string, number>> = { go: 1, pro: 2, max: 3 };

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
): boolean {
  if (!(row.planId in PLAN_RANK)) return false;
  if (!appleEnvironmentGrantsEntitlement(row, env)) return false;
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
): Row | null {
  let best: Row | null = null;
  for (const row of rows) {
    if (!appleSubscriptionGrantsAccess(row, now, env)) continue;
    if (!best || PLAN_RANK[row.planId]! > PLAN_RANK[best.planId]!) best = row;
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
    })
    .from(appleSubscriptions)
    .where(eq(appleSubscriptions.userId, userId));
}

/**
 * The user's granting Apple subscription (highest plan), or null. A
 * deployment without a database grants nothing, like the Stripe query.
 */
export async function activeAppleEntitlementForUser(
  userId: string,
  now: Date = new Date(),
): Promise<AppleEntitlementRow | null> {
  let rows: AppleEntitlementRow[];
  try {
    rows = await appleSubscriptionRowsForUser(userId);
  } catch (error) {
    if (error instanceof Error && /DATABASE_URL is required/.test(error.message)) return null;
    throw error;
  }
  // Lightweight database doubles in older tests may return non-array values.
  return Array.isArray(rows) ? bestAppleEntitlement(rows, now) : null;
}

export async function activeApplePlanForUser(userId: string): Promise<PersonalPlanId | null> {
  const row = await activeAppleEntitlementForUser(userId);
  return row ? row.planId as PersonalPlanId : null;
}
