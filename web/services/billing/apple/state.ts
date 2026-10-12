// Pure mapping from verified Apple data to cmux subscription state,
// transaction ledger rows, and lifecycle analytics events.

import type {
  JWSRenewalInfoDecodedPayload,
  JWSTransactionDecodedPayload,
} from "@apple/app-store-server-library";

import type { AppleSubscriptionStatus } from "../../../db/schema";
import type { PersonalPlanId } from "../pro";
import { APPLE_USD_LIST_PRICE, planIdForAppleProduct } from "./config";

export type AppleSubscriptionState = {
  readonly originalTransactionId: string;
  readonly appAccountToken: string | null;
  readonly bundleId: string;
  readonly environment: string;
  readonly productId: string;
  readonly planId: PersonalPlanId;
  readonly status: AppleSubscriptionStatus;
  readonly autoRenewEnabled: boolean | null;
  readonly autoRenewProductId: string | null;
  readonly purchaseDate: Date | null;
  readonly originalPurchaseDate: Date | null;
  readonly expiresAt: Date | null;
  readonly gracePeriodExpiresAt: Date | null;
  readonly storefront: string | null;
  readonly currency: string | null;
  readonly priceMilliunits: number | null;
  readonly lastTransactionId: string;
  readonly revokedAt: Date | null;
  readonly revocationReason: number | null;
  /** Apple `signedDate` of the newest data this state was built from. */
  readonly stateSignedAt: Date;
};

export type AppleStateInput = {
  readonly transaction: JWSTransactionDecodedPayload;
  readonly renewal?: JWSRenewalInfoDecodedPayload | null;
  /** Apple `status` from a notification or the Server API (1..5). */
  readonly appleStatus?: number | null;
  readonly notificationType?: string | null;
  readonly subtype?: string | null;
  /** Signed date of the envelope (notification) when newer than the parts. */
  readonly signedAt?: Date | null;
  readonly now?: Date;
};

export class AppleStateError extends Error {
  constructor(readonly reason: "missing_transaction_ids" | "unknown_product") {
    super(`Apple transaction cannot be mapped: ${reason}`);
    this.name = "AppleStateError";
  }
}

const APPLE_STATUS_CODES: Readonly<Record<number, AppleSubscriptionStatus>> = {
  1: "active",
  2: "expired",
  3: "billing_retry",
  4: "grace_period",
  5: "revoked",
};

function date(value: number | undefined | null): Date | null {
  return typeof value === "number" && Number.isFinite(value) ? new Date(value) : null;
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

/**
 * Subscription status from the most specific signal available: a revocation
 * on the transaction, then Apple's own status code, then the notification
 * type, then the dates.
 */
export function appleSubscriptionStatus(input: AppleStateInput): AppleSubscriptionStatus {
  const now = input.now ?? new Date();
  if (input.transaction.revocationDate !== undefined && input.transaction.revocationDate !== null) {
    return "revoked";
  }
  const fromCode = typeof input.appleStatus === "number" ? APPLE_STATUS_CODES[input.appleStatus] : undefined;
  if (fromCode) return fromCode;
  const fromType = statusFromNotificationType(input.notificationType, input.subtype);
  if (fromType) return fromType;
  if (input.renewal?.isInBillingRetryPeriod) {
    const grace = date(input.renewal.gracePeriodExpiresDate);
    return grace && grace > now ? "grace_period" : "billing_retry";
  }
  const expires = date(input.transaction.expiresDate);
  return expires && expires > now ? "active" : "expired";
}

function statusFromNotificationType(
  type: string | null | undefined,
  subtype: string | null | undefined,
): AppleSubscriptionStatus | null {
  switch (type) {
    case "EXPIRED":
      return "expired";
    case "GRACE_PERIOD_EXPIRED":
      return "billing_retry";
    case "DID_FAIL_TO_RENEW":
      return subtype === "GRACE_PERIOD" ? "grace_period" : "billing_retry";
    case "REFUND":
    case "REVOKE":
      return "revoked";
    case "SUBSCRIBED":
    case "DID_RENEW":
    case "REFUND_REVERSED":
      return "active";
    default:
      return null;
  }
}

/** Newest of the signed dates involved; Apple data never goes back in time. */
function stateSignedAt(input: AppleStateInput, now: Date): Date {
  const candidates = [
    input.signedAt?.getTime(),
    input.transaction.signedDate,
    input.renewal?.signedDate,
  ].filter((value): value is number => typeof value === "number" && Number.isFinite(value));
  return candidates.length > 0 ? new Date(Math.max(...candidates)) : now;
}

export function appleSubscriptionStateFrom(input: AppleStateInput): AppleSubscriptionState {
  const now = input.now ?? new Date();
  const { transaction, renewal } = input;
  const originalTransactionId = text(transaction.originalTransactionId);
  const transactionId = text(transaction.transactionId);
  const bundleId = text(transaction.bundleId);
  const productId = text(transaction.productId);
  if (!originalTransactionId || !transactionId || !bundleId || !productId) {
    throw new AppleStateError("missing_transaction_ids");
  }
  const planId = planIdForAppleProduct(productId, bundleId);
  if (!planId) throw new AppleStateError("unknown_product");
  return {
    originalTransactionId,
    appAccountToken: text(transaction.appAccountToken)?.toLowerCase() ?? null,
    bundleId,
    environment: text(transaction.environment) ?? "Production",
    productId,
    planId,
    status: appleSubscriptionStatus({ ...input, now }),
    autoRenewEnabled: typeof renewal?.autoRenewStatus === "number" ? renewal.autoRenewStatus === 1 : null,
    autoRenewProductId: text(renewal?.autoRenewProductId),
    purchaseDate: date(transaction.purchaseDate),
    originalPurchaseDate: date(transaction.originalPurchaseDate),
    expiresAt: date(transaction.expiresDate),
    gracePeriodExpiresAt: date(renewal?.gracePeriodExpiresDate),
    storefront: text(transaction.storefront),
    currency: text(transaction.currency),
    priceMilliunits: typeof transaction.price === "number" ? transaction.price : null,
    lastTransactionId: transactionId,
    revokedAt: date(transaction.revocationDate),
    revocationReason: typeof transaction.revocationReason === "number" ? transaction.revocationReason : null,
    stateSignedAt: stateSignedAt(input, now),
  };
}

export type AppleTransactionRow = {
  readonly transactionId: string;
  readonly originalTransactionId: string;
  readonly userId: string;
  readonly productId: string;
  readonly planId: string | null;
  readonly environment: string;
  readonly type: string | null;
  readonly purchaseDate: Date | null;
  readonly expiresAt: Date | null;
  readonly priceMilliunits: number | null;
  readonly currency: string | null;
  readonly storefront: string | null;
  readonly offerType: number | null;
  readonly revokedAt: Date | null;
  readonly payload: Record<string, unknown>;
};

/** `type` is Apple's `transactionReason` (`PURCHASE` or `RENEWAL`). */
export function appleTransactionRowFrom(
  transaction: JWSTransactionDecodedPayload,
  userId: string,
): AppleTransactionRow {
  return {
    transactionId: text(transaction.transactionId) ?? "",
    originalTransactionId: text(transaction.originalTransactionId) ?? "",
    userId,
    productId: text(transaction.productId) ?? "",
    planId: planIdForAppleProduct(transaction.productId, transaction.bundleId),
    environment: text(transaction.environment) ?? "Production",
    type: text(transaction.transactionReason),
    purchaseDate: date(transaction.purchaseDate),
    expiresAt: date(transaction.expiresDate),
    priceMilliunits: typeof transaction.price === "number" ? transaction.price : null,
    currency: text(transaction.currency),
    storefront: text(transaction.storefront),
    offerType: typeof transaction.offerType === "number" ? transaction.offerType : null,
    revokedAt: date(transaction.revocationDate),
    payload: { ...transaction } as Record<string, unknown>,
  };
}

export const SUBSCRIPTION_LIFECYCLE_EVENTS = [
  "subscription_started",
  "subscription_renewed",
  "subscription_plan_changed",
  "subscription_cancel_scheduled",
  "subscription_resubscribed",
  "subscription_billing_issue",
  "subscription_grace_period_entered",
  "subscription_expired",
  "subscription_refunded",
  "subscription_revoked",
] as const;
export type SubscriptionLifecycleEvent = (typeof SUBSCRIPTION_LIFECYCLE_EVENTS)[number];

const LIFECYCLE_BY_TYPE: Readonly<Record<string, SubscriptionLifecycleEvent>> = {
  DID_RENEW: "subscription_renewed",
  DID_CHANGE_RENEWAL_PREF: "subscription_plan_changed",
  EXPIRED: "subscription_expired",
  REFUND: "subscription_refunded",
  REVOKE: "subscription_revoked",
};

/**
 * The lifecycle event one notification represents, or null for types that
 * change no subscriber-visible state (price increase consent, renewal
 * extension, consumption request, test, refund reversal, auto-renew back on).
 */
export function lifecycleEventForNotification(
  type: string | null | undefined,
  subtype: string | null | undefined,
): SubscriptionLifecycleEvent | null {
  switch (type) {
    case "SUBSCRIBED":
      return subtype === "RESUBSCRIBE" ? "subscription_resubscribed" : "subscription_started";
    case "DID_CHANGE_RENEWAL_STATUS":
      return subtype === "AUTO_RENEW_DISABLED" ? "subscription_cancel_scheduled" : null;
    case "DID_FAIL_TO_RENEW":
      return subtype === "GRACE_PERIOD" ? "subscription_grace_period_entered" : "subscription_billing_issue";
    default:
      return type ? LIFECYCLE_BY_TYPE[type] ?? null : null;
  }
}

const YEAR_MS = 365 * 24 * 60 * 60 * 1000;

/**
 * Gross and net USD estimates. Apple keeps 30% in a subscriber's first year
 * of paid service and 15% after; the USD figure is exact for USD
 * storefronts and the plan's US list price elsewhere.
 */
export function appleRevenueEstimate(state: Pick<
  AppleSubscriptionState,
  "planId" | "currency" | "priceMilliunits" | "purchaseDate" | "originalPurchaseDate"
>): { price: number | null; priceUsd: number; netUsd: number; commission: number } {
  const price = state.priceMilliunits === null ? null : state.priceMilliunits / 1000;
  const priceUsd = state.currency === "USD" && price !== null ? price : APPLE_USD_LIST_PRICE[state.planId];
  const tenure = state.purchaseDate && state.originalPurchaseDate
    ? state.purchaseDate.getTime() - state.originalPurchaseDate.getTime()
    : 0;
  const commission = tenure >= YEAR_MS ? 0.15 : 0.3;
  return {
    price,
    priceUsd,
    netUsd: Math.round(priceUsd * (1 - commission) * 100) / 100,
    commission,
  };
}
