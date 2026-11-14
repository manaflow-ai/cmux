// Account deletion and App Store subscriptions (App Store Review Guideline
// 5.1.1(v)). Deleting a cmux account does not cancel an App Store
// subscription: Apple keeps charging until the subscriber cancels it in the
// App Store. Before deleting, the app and the dashboard warn a subscriber
// whose subscription will renew and link to Apple's subscription management.
// On deletion the Apple rows lose their link to the account, so a later App
// Store notification for that subscription is skipped as unlinked instead of
// granting a plan to a deleted account.

import { eq } from "drizzle-orm";

import type { cloudDb } from "../../../db/client";
import {
  appleAccountTokens,
  appleSubscriptions,
  appleTransactions,
  type AppleSubscriptionStatus,
} from "../../../db/schema";
import { DELETED_ACCOUNT_ACTOR_ID } from "../../auth/deletedAccount";
import { APPLE_MANAGE_SUBSCRIPTIONS_URL } from "./config";
import { appleSubscriptionRowsForUser, type AppleEntitlementRow } from "./entitlement";

/** Statuses in which Apple still charges at renewal (billing retry keeps retrying the charge). */
const RENEWING_STATUSES: ReadonlySet<AppleSubscriptionStatus | string> = new Set([
  "active",
  "grace_period",
  "billing_retry",
]);

/**
 * Environments whose subscriptions bill. Production charges real money.
 * Sandbox renews too, and App Review buys in the Sandbox against production,
 * so a reviewer who subscribes and then deletes the account sees the warning.
 * Xcode and local StoreKit testing never reach the server's rows.
 */
const BILLING_ENVIRONMENTS: ReadonlySet<string> = new Set(["Production", "Sandbox"]);

export type AccountDeletionCheck = {
  /** True when an App Store subscription on this account is set to renew. */
  readonly appStoreSubscriptionRenews: boolean;
  /** Where the subscriber cancels it: Apple's subscription management page. */
  readonly manageSubscriptionsUrl: string | null;
};

type RenewalRow = Pick<AppleEntitlementRow, "status" | "environment" | "autoRenewEnabled">;

/** A subscription Apple will charge again unless the subscriber cancels it. */
export function appleSubscriptionWillRenew(row: RenewalRow): boolean {
  return row.autoRenewEnabled === true &&
    RENEWING_STATUSES.has(row.status) &&
    BILLING_ENVIRONMENTS.has(row.environment);
}

/** The pre-delete answer for a set of the account's Apple subscription rows. */
export function accountDeletionCheckFor(rows: readonly RenewalRow[]): AccountDeletionCheck {
  const renews = rows.some(appleSubscriptionWillRenew);
  return {
    appStoreSubscriptionRenews: renews,
    manageSubscriptionsUrl: renews ? APPLE_MANAGE_SUBSCRIPTIONS_URL : null,
  };
}

/**
 * The pre-delete check for one account. A deployment without a database
 * has no Apple rows, like the entitlement lookup.
 */
export async function accountDeletionCheckForUser(userId: string): Promise<AccountDeletionCheck> {
  let rows: AppleEntitlementRow[];
  try {
    rows = await appleSubscriptionRowsForUser(userId);
  } catch (error) {
    if (error instanceof Error && /DATABASE_URL is required/.test(error.message)) return accountDeletionCheckFor([]);
    throw error;
  }
  return accountDeletionCheckFor(Array.isArray(rows) ? rows : []);
}

type AccountDeletionTransaction = Pick<ReturnType<typeof cloudDb>, "delete" | "update">;

/**
 * Drops the account's link to its Apple subscriptions, inside the account
 * deletion transaction:
 *
 * - `apple_account_tokens`: deleted, so the account's `appAccountToken`
 *   maps to no one and a purchase or notification carrying it is unlinked.
 * - `apple_subscriptions`: deleted. A notification for a subscription with
 *   no row and no token owner is closed as `skipped: unlinked_account`, and
 *   the lapse sweep never re-derives a plan for a deleted account. A new
 *   purchase by another cmux account carries that account's token and
 *   creates a fresh row for it.
 * - `apple_transactions`: kept as the revenue ledger, with `user_id` set to
 *   the deleted-account placeholder. `apple_notifications` has no user
 *   column and stays as received.
 */
export async function detachAppleBillingForAccountDeletion(
  tx: AccountDeletionTransaction,
  userId: string,
): Promise<void> {
  await tx.delete(appleAccountTokens).where(eq(appleAccountTokens.userId, userId));
  await tx.delete(appleSubscriptions).where(eq(appleSubscriptions.userId, userId));
  await tx
    .update(appleTransactions)
    .set({ userId: DELETED_ACCOUNT_ACTOR_ID })
    .where(eq(appleTransactions.userId, userId));
}
