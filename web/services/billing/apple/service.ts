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
import { appleBillingPeriodForProduct, isSignedAppleEnvironment } from "./config";
import { applyEntitlements, captureEntitlementGranted, errorText, tokenOwner } from "./effects";
import { activeAppleEntitlementForUser, type AppleEntitlementRow, type ApplePlanFamily } from "./entitlement";
import {
  isProductionLocked,
  productionAccessOf,
  withProductionAccess,
  type AppleProductionAccessTracker,
} from "./productionAccess";
import { runRenewalCheck, sweepLapsedSubscriptions, type AppleRecheckBudget } from "./recheck";
import { appleServerApi, type AppleServerApi } from "./serverApi";
import {
  appleRevenueEstimate,
  appleSubscriptionStateFrom,
  appleTransactionRowFrom,
  AppleStateError,
  isFamilySharedAppleTransaction,
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
/** App Store Server API status lookups one cron run may spend on re-checks. */
const RECHECK_CALLS_PER_RUN = 150;

export type AppleIapDependencies = {
  readonly store: AppleIapStore;
  readonly verifier: AppleSignedDataVerifier;
  readonly serverApi: AppleServerApi | null;
  /** Re-derives the user's `cmuxPlan` mirror from Stripe and Apple. */
  readonly applyEntitlement: (userId: string) => Promise<void>;
  readonly captureEvent: (input: ServerEventInput) => Promise<void>;
  /**
   * The user's granting Apple subscription after a write, used to report
   * `subscription_entitlement_granted`. Without it no grant event is sent.
   */
  /** The user's granting subscription of one plan family (classic when omitted). */
  readonly activeEntitlement?: (userId: string, family?: ApplePlanFamily) => Promise<AppleEntitlementRow | null>;
  readonly now: () => Date;
  /** Configuration source; defaults to `process.env`. */
  readonly env?: Record<string, string | undefined>;
  /**
   * What this run learned about Production access (productionAccess.ts);
   * the cron shares one across its steps. Without it each request asks anew.
   */
  readonly productionAccess?: AppleProductionAccessTracker;
};

/** A request the client can fix or must not retry; mapped to a 4xx. */
export class AppleTransactionRejectedError extends Error {
  constructor(
    readonly reason:
      | "invalid_transaction"
      | "not_subscription"
      | "unknown_product"
      | "account_mismatch"
      | "family_shared",
  ) {
    super(`Apple transaction rejected: ${reason}`);
    this.name = "AppleTransactionRejectedError";
  }
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
    activeEntitlement: (userId, family) => activeAppleEntitlementForUser(userId, { family }),
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
  /** True when Apple's current status answered; false for the fallback to the caller's own transaction. */
  readonly fromAppleStatus: boolean;
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
  const fallbackState = { transaction, renewal: null, appleStatus: null, fromAppleStatus: false };
  const fallback = (reason: AppleClientFallbackReason, error?: unknown) => {
    reportClientTransactionFallback(transaction, reason, error);
    return fallbackState;
  };
  const environment = transaction.environment;
  if (!deps.serverApi) return fallback("server_api_not_configured");
  if (!isSignedAppleEnvironment(environment)) return fallback("unsigned_environment");
  const access = environment === "Production" ? productionAccessOf(deps) : null;
  if (access?.isLocked(transaction.bundleId!)) return fallback("production_api_locked_until_release");
  try {
    const snapshot = await deps.serverApi.subscriptionStatus({
      originalTransactionId: transaction.originalTransactionId!,
      bundleId: transaction.bundleId!,
      environment,
    });
    access?.markOk(transaction.bundleId!);
    if (!snapshot) return fallback("no_status");
    const fresh = await deps.verifier.verifyTransaction(snapshot.signedTransactionInfo);
    if (fresh.originalTransactionId !== transaction.originalTransactionId) return fallback("transaction_mismatch");
    const renewal = snapshot.signedRenewalInfo
      ? await deps.verifier.verifyRenewalInfo(snapshot.signedRenewalInfo, {
          environment,
          bundleId: transaction.bundleId!,
        })
      : null;
    return { transaction: fresh, renewal, appleStatus: snapshot.status, fromAppleStatus: true };
  } catch (error) {
    // Before the first App Store release Production refuses every call: the
    // same fallback, under its own reason so the metric can leave it out.
    if (await isProductionLocked(access, error, transaction.bundleId!)) return fallback("production_api_locked_until_release");
    return fallback("lookup_failed", error);
  }
}

export type AppleClientFallbackReason =
  | "server_api_not_configured"
  | "unsigned_environment"
  | "no_status"
  | "transaction_mismatch"
  | "lookup_failed"
  /** Production answered 401 while the Sandbox accepts the key: no App Store release yet. */
  | "production_api_locked_until_release";

/**
 * Every time a path trusts the client's (or a notification's) own signed
 * transaction instead of Apple's current status, this structured warning is
 * logged under one stable name, so a log metric can count and alert on it.
 */
function reportClientTransactionFallback(
  transaction: JWSTransactionDecodedPayload,
  reason: AppleClientFallbackReason,
  error?: unknown,
): void {
  console.warn("apple_iap.client_transaction_fallback", {
    metric: "apple_iap.client_transaction_fallback",
    reason,
    environment: transaction.environment,
    bundleId: transaction.bundleId,
    originalTransactionId: transaction.originalTransactionId,
    ...(error === undefined ? {} : { error: errorText(error) }),
  });
}

function reportFamilyShared(transaction: JWSTransactionDecodedPayload, source: "client" | "notification"): void {
  console.warn("apple_iap.family_shared_refused", {
    metric: "apple_iap.family_shared_refused",
    source,
    environment: transaction.environment,
    bundleId: transaction.bundleId,
    originalTransactionId: transaction.originalTransactionId,
  });
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
  if (isFamilySharedAppleTransaction(transaction) || isFamilySharedAppleTransaction(fresh.transaction)) {
    // Audit only, attributed to the account that posted it (its token, if
    // any, already matched); never a grant.
    await deps.store.recordTransaction(appleTransactionRowFrom(transaction, input.userId));
    reportFamilyShared(transaction, "client");
    throw new AppleTransactionRejectedError("family_shared");
  }
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
  await captureEntitlementGranted(written, deps);
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
  | {
    readonly kind: "applied";
    readonly userId: string;
    readonly state: AppleSubscriptionState;
    readonly written: AppleSubscriptionRow;
  };

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
  if (isFamilySharedAppleTransaction(transaction)) {
    // Never touches a subscription row, not even the purchaser's (a REVOKE
    // of a family member's access must not revoke the purchaser).
    if (owner