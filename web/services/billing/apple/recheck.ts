// Asks the App Store Server API for a subscription's current state when a
// notification may have been missed: shortly before (and just after) an
// auto-renewing subscription's access ends, and before the lapse sweep
// expires a row. Grants are time-checked on every read (entitlement.ts), so
// a missed DID_RENEW would otherwise cut a paying user off at `expires_at`.
//
// The re-check only ever writes Apple state that keeps access (a renewal, a
// grace period, a plan change at renewal). Removing access stays with the
// paths that already retry durably: notifications (and the history
// backfill) through the ledger, and the time-based lapse sweep, which now
// expires a row only when Apple agrees, Apple has no status for it, or the
// Server API is not configured.

import { isSignedAppleEnvironment } from "./config";
import { applyEntitlements, captureEntitlementGranted, errorText, tokenOwner } from "./effects";
import { appleStatusGrantsAt } from "./entitlement";
import type { AppleIapDependencies } from "./service";
import {
  appleSubscriptionStateFrom,
  appleTransactionRowFrom,
  AppleStateError,
  isFamilySharedAppleTransaction,
  type AppleSubscriptionState,
} from "./state";
import { appleAccessEndsAt, type AppleLapsedSubscription, type AppleSubscriptionRow, type AppleSubscriptionWrite } from "./store";

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;

/** The sweep waits this long past a row's access end before acting on it. */
export const APPLE_LAPSE_LEEWAY_MS = HOUR;
/** The renewal re-check looks at rows whose access ends within this much time. */
export const APPLE_RENEWAL_LOOKAHEAD_MS = 6 * HOUR;
/** A row Apple answered for is not asked again for this long. */
export const APPLE_RECHECK_INTERVAL_MS = 25 * MINUTE;
/**
 * When Apple cannot be asked (an outage, or this run's call budget is
 * spent), the sweep defers a lapse for at most this long past its access
 * end, then expires it on Apple's last signed state as before.
 */
export const APPLE_MAX_LAPSE_DEFER_MS = 24 * HOUR;
const RENEWAL_CHECK_LIMIT = 100;
const LAPSE_SWEEP_LIMIT = 200;

/** Status lookups left in this cron run, shared by the re-check and the sweep. */
export type AppleRecheckBudget = { remaining: number };

type RecheckTarget = Pick<AppleSubscriptionRow, "originalTransactionId" | "bundleId" | "environment">;

export type AppleRefreshOutcome =
  /** Apple's state keeps access now and differs from the row; it was written and the plan re-derived. */
  | { readonly kind: "granting"; readonly write: AppleSubscriptionWrite }
  /** Apple's state keeps access and matches the row (no renewal yet); nothing was written. */
  | { readonly kind: "unchanged" }
  /** Apple answered, and its state does not keep access (or is older than the row). */
  | { readonly kind: "not_granting" }
  /** Apple has no usable status for this transaction. */
  | { readonly kind: "unknown" }
  /** The lookup or its verification failed; nothing is known. */
  | { readonly kind: "error" }
  /** Not asked: no Server API, an unsigned environment, or no budget left. */
  | { readonly kind: "skipped" };

type AppleAnswer =
  | { readonly kind: "state"; readonly state: AppleSubscriptionState; readonly transaction: Parameters<typeof appleTransactionRowFrom>[0] }
  | { readonly kind: "unknown" }
  | { readonly kind: "error" };

/** Apple's verified current state for one subscription. */
async function askApple(target: RecheckTarget, deps: AppleIapDependencies): Promise<AppleAnswer> {
  const environment = target.environment;
  if (!deps.serverApi || !isSignedAppleEnvironment(environment)) return { kind: "error" };
  try {
    const snapshot = await deps.serverApi.subscriptionStatus({
      originalTransactionId: target.originalTransactionId,
      bundleId: target.bundleId,
      environment,
    });
    if (!snapshot) return { kind: "unknown" };
    const transaction = await deps.verifier.verifyTransaction(snapshot.signedTransactionInfo);
    if (transaction.originalTransactionId !== target.originalTransactionId || transaction.bundleId !== target.bundleId) {
      throw new Error("Apple status describes another subscription");
    }
    // A Family Sharing transaction never grants (only the purchaser does).
    if (isFamilySharedAppleTransaction(transaction)) return { kind: "unknown" };
    const renewal = snapshot.signedRenewalInfo
      ? await deps.verifier.verifyRenewalInfo(snapshot.signedRenewalInfo, { environment, bundleId: target.bundleId })
      : null;
    const state = appleSubscriptionStateFrom({ transaction, renewal, appleStatus: snapshot.status, now: deps.now() });
    return { kind: "state", state, transaction };
  } catch (error) {
    // An unknown product can never grant here; Apple's answer is final.
    if (error instanceof AppleStateError) return { kind: "unknown" };
    console.warn("apple_iap.status_lookup_failed", {
      metric: "apple_iap.status_lookup_failed",
      originalTransactionId: target.originalTransactionId,
      environment,
      error: errorText(error),
    });
    return { kind: "error" };
  }
}

/**
 * Asks Apple for the subscription's current state and writes it through the
 * normal forward-only, advisory-locked state write when it keeps access.
 * `apple_checked_at` is recorded only once the outcome is settled, so a
 * failed write is asked about again.
 */
export async function refreshSubscriptionFromApple(
  target: RecheckTarget,
  deps: AppleIapDependencies,
  budget: AppleRecheckBudget,
): Promise<AppleRefreshOutcome> {
  if (!deps.serverApi || !isSignedAppleEnvironment(target.environment) || budget.remaining <= 0) {
    return { kind: "skipped" };
  }
  budget.remaining -= 1;
  const answer = await askApple(target, deps);
  if (answer.kind === "error") return answer;
  const now = deps.now();
  if (answer.kind === "unknown" || !appleStatusGrantsAt(answer.state, now)) {
    await deps.store.markAppleChecked(target.originalTransactionId, now);
    return answer.kind === "unknown" ? answer : { kind: "not_granting" };
  }
  const { state, transaction } = answer;
  const current = await deps.store.subscription(target.originalTransactionId);
  if (current && sameAccess(current, state)) {
    await deps.store.markAppleChecked(target.originalTransactionId, now);
    return { kind: "unchanged" };
  }
  const write = await deps.store.writeSubscriptionState(state, {
    tokenOwner: await tokenOwner(state.appAccountToken, deps.store),
  });
  await deps.store.markAppleChecked(target.originalTransactionId, now);
  if (!write.applied) return { kind: "not_granting" };
  await deps.store.recordTransaction(appleTransactionRowFrom(transaction, write.current.userId));
  await applyEntitlements(write, deps);
  await captureEntitlementGranted(write.current, deps);
  return { kind: "granting", write };
}

/** Apple's state describes the same period and access as the row, so writing it would change nothing that matters. */
function sameAccess(row: AppleSubscriptionRow, state: AppleSubscriptionState): boolean {
  const time = (value: Date | null) => value?.getTime() ?? null;
  return row.lastTransactionId === state.lastTransactionId &&
    row.status === state.status &&
    row.planId === state.planId &&
    row.productId === state.productId &&
    row.autoRenewEnabled === state.autoRenewEnabled &&
    row.autoRenewProductId === state.autoRenewProductId &&
    time(row.expiresAt) === time(state.expiresAt) &&
    time(row.gracePeriodExpiresAt) === time(state.gracePeriodExpiresAt);
}

async function refreshOrError(
  target: RecheckTarget,
  deps: AppleIapDependencies,
  budget: AppleRecheckBudget,
): Promise<AppleRefreshOutcome> {
  try {
    return await refreshSubscriptionFromApple(target, deps, budget);
  } catch (error) {
    console.error("apple_iap.recheck_write_failed", {
      metric: "apple_iap.recheck_write_failed",
      originalTransactionId: target.originalTransactionId,
      error: errorText(error),
    });
    return { kind: "error" };
  }
}

export type AppleRenewalCheckResult = {
  readonly checked: number;
  readonly extended: number;
  readonly failures: number;
};

/**
 * Asks Apple about `active` and `grace_period` rows whose access ends within
 * APPLE_RENEWAL_LOOKAHEAD_MS (or ended within the sweep's leeway) and that
 * Apple has not answered for in APPLE_RECHECK_INTERVAL_MS. Rows stored with
 * auto-renew off are asked about too, since the notification that turned it
 * back on can be the one that was missed; an answer that matches the row
 * writes nothing.
 * A renewal Apple already charged moves `expires_at` forward before the old
 * one passes. Runs only in the cron, never on a plan read, so reads stay one
 * database query; with the cron every 30 minutes a row is asked about at
 * most every 25 minutes and only while its end is near.
 */
export async function runRenewalCheck(
  deps: AppleIapDependencies,
  budget: AppleRecheckBudget,
): Promise<AppleRenewalCheckResult> {
  if (!deps.serverApi || budget.remaining <= 0) return { checked: 0, extended: 0, failures: 0 };
  const now = deps.now();
  const limit = Math.min(RENEWAL_CHECK_LIMIT, budget.remaining);
  const rows = await deps.store.renewalCheckCandidates({
    accessEndsAfter: new Date(now.getTime() - APPLE_LAPSE_LEEWAY_MS),
    accessEndsBy: new Date(now.getTime() + APPLE_RENEWAL_LOOKAHEAD_MS),
    checkedBefore: new Date(now.getTime() - APPLE_RECHECK_INTERVAL_MS),
    limit,
  });
  if (rows.length >= limit) {
    // More renewals are due than one run may ask about; raise the budget.
    console.warn("apple_iap.renewal_check_saturated", { metric: "apple_iap.renewal_check_saturated", limit });
  }
  let checked = 0;
  let extended = 0;
  let failures = 0;
  for (const row of rows) {
    if (budget.remaining <= 0) break;
    const outcome = await refreshOrError(row, deps, budget);
    // An unsigned environment is never asked; it must not block the rows after it.
    if (outcome.kind === "skipped") continue;
    checked += 1;
    if (outcome.kind === "error") failures += 1;
    if (outcome.kind === "granting" && endsLater(outcome.write.current, row)) extended += 1;
  }
  return { checked, extended, failures };
}

function endsLater(
  next: Pick<AppleSubscriptionRow, "expiresAt" | "gracePeriodExpiresAt">,
  previous: Pick<AppleSubscriptionRow, "expiresAt" | "gracePeriodExpiresAt">,
): boolean {
  const after = appleAccessEndsAt(next)?.getTime() ?? 0;
  const before = appleAccessEndsAt(previous)?.getTime() ?? 0;
  return after > before;
}

type LapseDecision = "expire" | "recovered" | "defer";

/**
 * Whether the sweep may expire one lapsed row. Without the Server API the
 * row expires on Apple's last signed state, as before. With it, Apple is
 * asked first unless it already answered after the lapse within the
 * re-check interval.
 */
async function lapseDecision(
  row: AppleLapsedSubscription,
  deps: AppleIapDependencies,
  budget: AppleRecheckBudget,
  now: Date,
): Promise<LapseDecision> {
  if (!deps.serverApi || !isSignedAppleEnvironment(row.environment)) return "expire";
  const endsAt = appleAccessEndsAt(row)!;
  const checkedAt = row.appleCheckedAt?.getTime() ?? 0;
  if (checkedAt >= endsAt.getTime() && checkedAt > now.getTime() - APPLE_RECHECK_INTERVAL_MS) return "expire";
  const outcome = await refreshOrError(row, deps, budget);
  switch (outcome.kind) {
    case "granting":
    case "unchanged":
      return "recovered";
    case "not_granting":
    case "unknown":
      return "expire";
    default:
      return endsAt.getTime() < now.getTime() - APPLE_MAX_LAPSE_DEFER_MS ? "expire" : "defer";
  }
}

export type AppleLapseSweepResult = {
  readonly lapsedUsers: number;
  readonly failures: number;
  readonly deferredUsers: number;
  readonly recovered: number;
};

/**
 * Re-derives the plan for users whose Apple subscription passed its expiry
 * or grace period, plus APPLE_LAPSE_LEEWAY_MS, without a notification (a
 * missed EXPIRED or GRACE_PERIOD_EXPIRED), then marks those rows swept. A
 * row Apple shows as still granting is written instead (recovered). A user
 * with a row Apple could not be asked about is left for the next run,
 * within APPLE_MAX_LAPSE_DEFER_MS. A lapse is marked swept only after its
 * user's plan was re-derived, so a failure is retried on the next run.
 */
export async function sweepLapsedSubscriptions(
  deps: AppleIapDependencies,
  budget: AppleRecheckBudget,
): Promise<AppleLapseSweepResult> {
  const now = deps.now();
  const cutoff = new Date(now.getTime() - APPLE_LAPSE_LEEWAY_MS);
  const users = new Map<string, { expire: string[]; deferred: boolean }>();
  let recovered = 0;
  for (const row of await deps.store.lapsedSubscriptions(cutoff, LAPSE_SWEEP_LIMIT)) {
    const entry = users.get(row.userId) ?? { expire: [], deferred: false };
    users.set(row.userId, entry);
    const decision = await lapseDecision(row, deps, budget, now);
    if (decision === "recovered") recovered += 1;
    if (decision === "defer") entry.deferred = true;
    if (decision === "expire") entry.expire.push(row.originalTransactionId);
  }
  let lapsedUsers = 0;
  let failures = 0;
  let deferredUsers = 0;
  for (const [userId, entry] of users) {
    if (entry.deferred) {
      deferredUsers += 1;
      continue;
    }
    if (entry.expire.length === 0) continue;
    lapsedUsers += 1;
    try {
      await deps.applyEntitlement(userId);
      await deps.store.markLapseSwept(entry.expire, now);
    } catch {
      failures += 1;
    }
  }
  return { lapsedUsers, failures, deferredUsers, recovered };
}
