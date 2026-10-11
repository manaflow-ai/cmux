// iOS in-app purchase flows: client-posted StoreKit transactions, App Store
// Server Notifications V2, and the retry job. The flows share one rule:
// verify, record, move subscription state forward only, then re-derive the
// personal plan from every source (pro.ts) so Stripe and Apple never erase
// each other's grant.

import type {
  JWSRenewalInfoDecodedPayload,
  JWSTransactionDecodedPayload,
  ResponseBodyV2DecodedPayload,
} from "@apple/app-store-server-library";

import { captureServerEvent, type ServerEventInput } from "../../analytics/serverEvents";
import { isSignedAppleEnvironment } from "./config";
import { appleServerApi, type AppleServerApi } from "./serverApi";
import {
  appleRevenueEstimate,
  appleSubscriptionStateFrom,
  appleTransactionRowFrom,
  AppleStateError,
  lifecycleEventForNotification,
  type AppleSubscriptionState,
} from "./state";
import {
  AppleOwnershipError,
  databaseAppleIapStore,
  isOlderAppleTransaction,
  type AppleIapStore,
  type AppleNotificationRow,
  type AppleSubscriptionRow,
  type AppleSubscriptionWrite,
} from "./store";
import { appleSignedDataVerifier, AppleVerificationError, type AppleSignedDataVerifier } from "./verifier";

const AUTO_RENEWABLE_TYPE = "Auto-Renewable Subscription";
const LAPSE_SWEEP_LIMIT = 200;

export type AppleIapDependencies = {
  readonly store: AppleIapStore;
  readonly verifier: AppleSignedDataVerifier;
  readonly serverApi: AppleServerApi | null;
  /** Re-derives the user's `cmuxPlan` mirror from Stripe and Apple. */
  readonly applyEntitlement: (userId: string) => Promise<void>;
  readonly captureEvent: (input: ServerEventInput) => Promise<void>;
  readonly now: () => Date;
};

/** A request the client can fix or must not retry; mapped to a 4xx. */
export class AppleTransactionRejectedError extends Error {
  constructor(
    readonly reason:
      | "invalid_transaction"
      | "not_subscription"
      | "unknown_product"
      | "account_mismatch",
  ) {
    super(`Apple transaction rejected: ${reason}`);
    this.name = "AppleTransactionRejectedError";
  }
}

async function tokenOwner(token: string | null | undefined, store: AppleIapStore): Promise<string | null> {
  return token ? await store.userIdForAccountToken(token) : null;
}

/**
 * Re-derives the plan of the subscription's owner and, after an ownership
 * move, of the previous owner, who falls back to Stripe or free.
 */
async function applyEntitlements(write: AppleSubscriptionWrite, deps: AppleIapDependencies): Promise<void> {
  await deps.applyEntitlement(write.current.userId);
  if (write.transferredFrom) await deps.applyEntitlement(write.transferredFrom);
}

let defaultDependencies: AppleIapDependencies | null = null;

export function defaultAppleIapDependencies(): AppleIapDependencies {
  defaultDependencies ??= {
    store: databaseAppleIapStore(),
    verifier: appleSignedDataVerifier(),
    serverApi: appleServerApi(),
    applyEntitlement: async (userId) => {
      const { applyPersonalPlanEntitlement } = await import("./applyEntitlement");
      await applyPersonalPlanEntitlement(userId);
    },
    captureEvent: (input) => captureServerEvent(input),
    now: () => new Date(),
  };
  return defaultDependencies;
}

export type AppleTransactionResult = {
  readonly planId: string;
  readonly status: string;
  readonly expiresAt: string | null;
};

type FreshAppleState = {
  readonly transaction: JWSTransactionDecodedPayload;
  readonly renewal: JWSRenewalInfoDecodedPayload | null;
  readonly appleStatus: number | null;
};

/**
 * Apple's current signed state for the subscription. Falls back to the
 * client's verified transaction when this deployment has no Server API key
 * or Apple is unreachable; the stored state's signed date still keeps an
 * older client payload from overwriting newer state.
 */
async function freshAppleState(
  transaction: JWSTransactionDecodedPayload,
  deps: AppleIapDependencies,
): Promise<FreshAppleState> {
  const fallback = { transaction, renewal: null, appleStatus: null };
  const environment = transaction.environment;
  if (!deps.serverApi || !isSignedAppleEnvironment(environment)) return fallback;
  try {
    const snapshot = await deps.serverApi.subscriptionStatus({
      originalTransactionId: transaction.originalTransactionId!,
      bundleId: transaction.bundleId!,
      environment,
    });
    if (!snapshot) return fallback;
    const fresh = await deps.verifier.verifyTransaction(snapshot.signedTransactionInfo);
    if (fresh.originalTransactionId !== transaction.originalTransactionId) return fallback;
    const renewal = snapshot.signedRenewalInfo
      ? await deps.verifier.verifyRenewalInfo(snapshot.signedRenewalInfo, {
          environment,
          bundleId: transaction.bundleId!,
        })
      : null;
    return { transaction: fresh, renewal, appleStatus: snapshot.status };
  } catch (error) {
    console.warn("Apple Server API status lookup failed; using the client transaction", {
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
    return fallback;
  }
}

/**
 * Replay guard: a token cmux minted must map to the caller, so one account
 * cannot post another account's transaction. A transaction without a token
 * (an offer code redeemed outside the app) may be claimed only while no other
 * account owns it, which the subscription write enforces.
 */
async function assertTransactionOwner(
  transaction: JWSTransactionDecodedPayload,
  userId: string,
  store: AppleIapStore,
): Promise<void> {
  const token = transaction.appAccountToken;
  if (!token) return;
  const owner = await store.userIdForAccountToken(token);
  if (owner !== userId) throw new AppleTransactionRejectedError("account_mismatch");
}

function stateOrReject(build: () => AppleSubscriptionState): AppleSubscriptionState {
  try {
    return build();
  } catch (error) {
    if (error instanceof AppleStateError) {
      throw new AppleTransactionRejectedError(
        error.reason === "unknown_product" ? "unknown_product" : "invalid_transaction",
      );
    }
    throw error;
  }
}

/** `POST /api/billing/apple/transactions`. Idempotent. */
export async function recordClientAppleTransaction(
  input: { readonly userId: string; readonly signedTransactionInfo: unknown },
  deps: AppleIapDependencies = defaultAppleIapDependencies(),
): Promise<AppleTransactionResult> {
  if (typeof input.signedTransactionInfo !== "string") {
    throw new AppleTransactionRejectedError("invalid_transaction");
  }
  const transaction = await deps.verifier.verifyTransaction(input.signedTransactionInfo);
  if (transaction.type !== AUTO_RENEWABLE_TYPE) throw new AppleTransactionRejectedError("not_subscription");
  if (!transaction.originalTransactionId || !transaction.transactionId) {
    throw new AppleTransactionRejectedError("invalid_transaction");
  }
  await assertTransactionOwner(transaction, input.userId, deps.store);
  const fresh = await freshAppleState(transaction, deps);
  const state = stateOrReject(() => appleSubscriptionStateFrom({ ...fresh, now: deps.now() }));
  let write: AppleSubscriptionWrite;
  try {
    // Apple's newest transaction decides the owner; the caller must end up
    // owning the subscription or the request is refused.
    write = await deps.store.writeSubscriptionState(state, {
      tokenOwner: await tokenOwner(state.appAccountToken, deps.store),
      caller: input.userId,
    });
  } catch (error) {
    if (error instanceof AppleOwnershipError) throw new AppleTransactionRejectedError("account_mismatch");
    throw error;
  }
  const written = write.current;
  await deps.store.recordTransaction(appleTransactionRowFrom(transaction, input.userId));
  if (fresh.transaction !== transaction) {
    await deps.store.recordTransaction(appleTransactionRowFrom(fresh.transaction, input.userId));
  }
  await applyEntitlements(write, deps);
  return {
    planId: written.planId,
    status: written.status,
    expiresAt: written.expiresAt?.toISOString() ?? null,
  };
}

type StoredNotificationData = {
  readonly status?: number;
  readonly transactionInfo?: JWSTransactionDecodedPayload;
  readonly renewalInfo?: JWSRenewalInfoDecodedPayload;
};

function notificationEnvironment(payload: ResponseBodyV2DecodedPayload): string {
  return String(payload.data?.environment ?? payload.summary?.environment ?? "unknown");
}

/**
 * Verifies the nested transaction and renewal JWS. They are signed
 * separately, so they are verified here rather than trusted because the
 * envelope verified. The stored copy keeps the decoded values only.
 */
async function verifiedNotificationData(
  data: ResponseBodyV2DecodedPayload["data"],
  deps: AppleIapDependencies,
): Promise<StoredNotificationData & Record<string, unknown>> {
  if (!data) return {};
  const transactionInfo = data.signedTransactionInfo
    ? await deps.verifier.verifyTransaction(data.signedTransactionInfo)
    : undefined;
  const environment = data.environment;
  const renewalInfo = data.signedRenewalInfo && isSignedAppleEnvironment(environment) && data.bundleId
    ? await deps.verifier.verifyRenewalInfo(data.signedRenewalInfo, { environment, bundleId: data.bundleId })
    : undefined;
  return {
    environment: data.environment,
    bundleId: data.bundleId,
    appAppleId: data.appAppleId,
    bundleVersion: data.bundleVersion,
    status: typeof data.status === "number" ? data.status : undefined,
    consumptionRequestReason: data.consumptionRequestReason,
    transactionInfo,
    renewalInfo,
  };
}

/** Verifies the envelope and its nested JWS, and returns the ledger row. */
async function verifiedNotificationRow(signedPayload: unknown, deps: AppleIapDependencies) {
  if (typeof signedPayload !== "string") throw new AppleVerificationError("malformed");
  const payload = await deps.verifier.verifyNotification(signedPayload);
  if (!payload.notificationUUID || !payload.notificationType) throw new AppleVerificationError("malformed");
  const data = await verifiedNotificationData(payload.data, deps);
  return {
    notificationUuid: payload.notificationUUID,
    notificationType: String(payload.notificationType),
    subtype: payload.subtype ? String(payload.subtype) : null,
    environment: notificationEnvironment(payload),
    originalTransactionId: data.transactionInfo?.originalTransactionId ?? null,
    signedDate: new Date(payload.signedDate ?? deps.now().getTime()),
    payload: JSON.parse(JSON.stringify({
      notificationType: payload.notificationType,
      subtype: payload.subtype,
      notificationUUID: payload.notificationUUID,
      version: payload.version,
      signedDate: payload.signedDate,
      data,
      summary: payload.summary,
    })) as Record<string, unknown>,
  };
}

export type AppleNotificationOutcome = "processed" | "duplicate" | "skipped" | "failed";

/**
 * `POST /api/billing/apple/notifications`. Throws AppleVerificationError for
 * a payload that fails verification (4xx). Anything after the durable ledger
 * write is reported as an outcome, never thrown, so Apple gets a 200 and the
 * retry job owns the rest.
 */
export async function receiveAppleNotification(
  signedPayload: unknown,
  deps: AppleIapDependencies = defaultAppleIapDependencies(),
): Promise<AppleNotificationOutcome> {
  const ledger = await verifiedNotificationRow(signedPayload, deps);
  const { inserted, row } = await deps.store.insertNotification(ledger);
  if (!inserted && row.processedAt) return "duplicate";
  try {
    return await processAppleNotification(row, deps);
  } catch {
    // The ledger row is durable and still pending; the retry job finishes it.
    return "failed";
  }
}

type NotificationApplication =
  | { readonly kind: "skip"; readonly reason: string }
  | { readonly kind: "applied"; readonly userId: string; readonly state: AppleSubscriptionState };

async function applyNotification(
  row: AppleNotificationRow,
  deps: AppleIapDependencies,
): Promise<NotificationApplication> {
  const data = (row.payload.data ?? {}) as StoredNotificationData;
  const transaction = data.transactionInfo;
  // TEST and CONSUMPTION_REQUEST are recorded only; summaries carry no state.
  if (!transaction || row.notificationType === "TEST" || row.notificationType === "CONSUMPTION_REQUEST") {
    return { kind: "skip", reason: "no_state_change" };
  }
  if (transaction.type !== AUTO_RENEWABLE_TYPE || !transaction.originalTransactionId) {
    return { kind: "skip", reason: "not_subscription" };
  }
  const owner = await tokenOwner(transaction.appAccountToken, deps.store);
  const existing = await deps.store.subscription(transaction.originalTransactionId);
  if (!owner && !existing) return { kind: "skip", reason: "unlinked_account" };
  let state: AppleSubscriptionState;
  try {
    state = appleSubscriptionStateFrom({
      transaction,
      renewal: data.renewalInfo ?? null,
      appleStatus: data.status ?? null,
      notificationType: row.notificationType,
      subtype: row.subtype,
      signedAt: row.signedDate,
      now: deps.now(),
    });
  } catch (error) {
    if (error instanceof AppleStateError) return { kind: "skip", reason: error.reason };
    throw error;
  }
  // An older notification still records its transaction; the state write
  // ignores it when the stored state is newer or describes a newer
  // transaction. A newer purchase whose token maps to another user moves the
  // subscription to that user.
  const current = await currentSubscriptionState(state, transaction, existing, deps);
  const write = await deps.store.writeSubscriptionState(current.state, {
    tokenOwner: current.transaction === transaction ? owner : await tokenOwner(current.state.appAccountToken, deps.store),
  });
  const userId = write.current.userId;
  // The ledger row belongs to whoever bought that transaction.
  await deps.store.recordTransaction(appleTransactionRowFrom(transaction, owner ?? userId));
  if (current.transaction !== transaction) {
    await deps.store.recordTransaction(appleTransactionRowFrom(current.transaction, userId));
  }
  await applyEntitlements(write, deps);
  return { kind: "applied", userId, state };
}

/**
 * The state to write for a notification. A notification about an older
 * transaction than the stored one (a refund or refund decision about a past
 * period) says nothing about the current period, so Apple's current status
 * is fetched when the Server API is configured. Without it, the notification's
 * own state goes to the store, which keeps the newer row.
 */
async function currentSubscriptionState(
  notified: AppleSubscriptionState,
  transaction: JWSTransactionDecodedPayload,
  existing: AppleSubscriptionRow | null,
  deps: AppleIapDependencies,
): Promise<{ readonly state: AppleSubscriptionState; readonly transaction: JWSTransactionDecodedPayload }> {
  const unchanged = { state: notified, transaction };
  if (!existing || !deps.serverApi || !isOlderAppleTransaction(notified, existing)) return unchanged;
  const fresh = await freshAppleState(transaction, deps);
  if (fresh.transaction === transaction) return unchanged;
  try {
    return { state: appleSubscriptionStateFrom({ ...fresh, now: deps.now() }), transaction: fresh.transaction };
  } catch (error) {
    if (error instanceof AppleStateError) return unchanged;
    throw error;
  }
}

/** Applies one ledger row; shared by the webhook and the retry job. */
export async function processAppleNotification(
  row: AppleNotificationRow,
  deps: AppleIapDependencies = defaultAppleIapDependencies(),
): Promise<AppleNotificationOutcome> {
  let application: NotificationApplication;
  try {
    application = await applyNotification(row, deps);
  } catch (error) {
    const message = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
    await deps.store.markNotificationFailed(row.notificationUuid, message).catch(() => undefined);
    console.error("Apple notification application failed; the retry job will re-apply it", {
      notificationUuid: row.notificationUuid,
      notificationType: row.notificationType,
      error: message.slice(0, 200),
    });
    return "failed";
  }
  if (application.kind === "skip") {
    await deps.store.markNotificationSkipped(row.notificationUuid, application.reason, deps.now());
    return "skipped";
  }
  await deps.store.markNotificationProcessed(row.notificationUuid, deps.now());
  await captureLifecycleEvent(row, application.userId, application.state, deps);
  return "processed";
}

async function captureLifecycleEvent(
  row: AppleNotificationRow,
  userId: string,
  state: AppleSubscriptionState,
  deps: AppleIapDependencies,
): Promise<void> {
  const event = lifecycleEventForNotification(row.notificationType, row.subtype);
  if (!event) return;
  const revenue = appleRevenueEstimate(state);
  await deps.captureEvent({
    event,
    distinctId: userId,
    // The notification UUID dedupes a retried application.
    insertId: `apple:${row.notificationUuid}`,
    timestamp: row.signedDate,
    properties: {
      source: "apple",
      plan_id: state.planId,
      product_id: state.productId,
      storefront: state.storefront,
      currency: state.currency,
      price: revenue.price,
      price_usd_estimate: revenue.priceUsd,
      net_usd_estimate: revenue.netUsd,
      environment: state.environment,
      original_transaction_id: state.originalTransactionId,
      notification_type: row.notificationType,
      notification_subtype: row.subtype,
      auto_renew_product_id: state.autoRenewProductId,
    },
  }).catch(() => undefined);
}

export type AppleRetryResult = {
  readonly notifications: Record<AppleNotificationOutcome, number>;
  readonly lapsedUsers: number;
  readonly lapsedFailures: number;
};

/**
 * Re-applies ledger rows that never finished, then re-derives the plan for
 * users whose Apple subscription passed its expiry or grace period without a
 * notification (a missed EXPIRED or GRACE_PERIOD_EXPIRED), so time alone
 * ends a grant. A lapse is marked swept only after its user's plan was
 * re-derived, so a failure is retried on the next run.
 */
export async function retryAppleNotifications(
  options: { readonly limit?: number } = {},
  deps: AppleIapDependencies = defaultAppleIapDependencies(),
): Promise<AppleRetryResult> {
  const counts: Record<AppleNotificationOutcome, number> = { processed: 0, duplicate: 0, skipped: 0, failed: 0 };
  const pending = await deps.store.pendingNotifications(options.limit ?? 100);
  for (const row of pending) {
    counts[await processAppleNotification(row, deps)] += 1;
  }
  const now = deps.now();
  const lapsedByUser = new Map<string, string[]>();
  for (const row of await deps.store.lapsedSubscriptions(now, LAPSE_SWEEP_LIMIT)) {
    lapsedByUser.set(row.userId, [...(lapsedByUser.get(row.userId) ?? []), row.originalTransactionId]);
  }
  let lapsedFailures = 0;
  for (const [userId, originalTransactionIds] of lapsedByUser) {
    try {
      await deps.applyEntitlement(userId);
      await deps.store.markLapseSwept(originalTransactionIds, now);
    } catch {
      lapsedFailures += 1;
    }
  }
  return { notifications: counts, lapsedUsers: lapsedByUser.size, lapsedFailures };
}
