// Normalizes Apple and Stripe billing rows into one subscription model for
// analytics. Pure: no database access, every input is a plain row.
//
// A subscription is a list of coverage intervals. Each interval is one
// billing period (an Apple transaction, or the whole known life of a Stripe
// subscription, whose mirror keeps no per-period history) with its monthly
// gross price in USD. Every metric is a question about which intervals cover
// a moment in time.

import { APPLE_USD_LIST_PRICE } from "../apple/config";
import { GO_PRICING_USD, MAX_PRICING_USD, PRO_PRICING_USD, TEAM_PRICING_USD } from "../plans";
import { toUsd } from "./fx";

export type AnalyticsSource = "apple" | "stripe";
export type AnalyticsEnvironment = "production" | "sandbox";

export type CoverageInterval = {
  readonly start: Date;
  /** Exclusive end; null while a Stripe subscription is still running. */
  readonly end: Date | null;
  readonly planId: string;
  /** Gross price normalized to one month, USD (estimate when FX applied). */
  readonly monthlyGrossUsd: number;
  /** Gross amount of the one charge that opened this period, USD. */
  readonly chargeUsd: number;
  readonly intervalMonths: number;
  /** False for free trials and introductory free periods. */
  readonly paid: boolean;
  /** True when this interval is a real charge (an Apple transaction). */
  readonly isCharge: boolean;
};

export type CurrentStatus = "active" | "trial" | "grace_period" | "billing_issue" | "inactive";

export type SubscriptionRecord = {
  readonly source: AnalyticsSource;
  readonly id: string;
  readonly userId: string;
  /** Plan of the newest interval (the one billed now, or last billed). */
  readonly planId: string;
  readonly environment: AnalyticsEnvironment;
  /** Status from the provider's current state, not reconstructed history. */
  readonly currentStatus: CurrentStatus;
  readonly cancelScheduled: boolean;
  /** Storefront country (ISO 3166 alpha-3) for Apple; null for Stripe. */
  readonly country: string | null;
  readonly currency: string | null;
  /** Sorted by start. */
  readonly intervals: readonly CoverageInterval[];
  /** Why the final paid run ended, when it has ended. */
  readonly endReason: "expired" | "revoked" | "canceled" | null;
  /** Count of prices estimated from a list price (missing price or unknown currency). */
  readonly fxFallbacks: number;
};

export type RefundEvent = {
  readonly source: AnalyticsSource;
  readonly id: string;
  readonly subscriptionId: string;
  readonly at: Date;
  readonly amountUsd: number;
  readonly planId: string;
  readonly country: string | null;
  readonly environment: AnalyticsEnvironment;
};

const DAY_MS = 24 * 60 * 60 * 1000;
const AVERAGE_MONTH_DAYS = 30.44;

/** Apple reports `Production`; Sandbox, Xcode, and LocalTesting are test data. */
export function appleEnvironment(value: string | null | undefined): AnalyticsEnvironment {
  return value === "Production" ? "production" : "sandbox";
}

/** Months in one billing period, from its dates (monthly products give 1). */
export function periodMonths(start: Date, end: Date | null): number {
  if (!end) return 1;
  const days = (end.getTime() - start.getTime()) / DAY_MS;
  return Math.max(1, Math.round(days / AVERAGE_MONTH_DAYS));
}

// ---------------------------------------------------------------- Apple

export type AppleSubscriptionInput = {
  readonly originalTransactionId: string;
  readonly userId: string;
  readonly environment: string;
  readonly planId: string;
  readonly status: string;
  readonly autoRenewEnabled: boolean | null;
  readonly purchaseDate: Date | null;
  readonly originalPurchaseDate: Date | null;
  readonly expiresAt: Date | null;
  readonly gracePeriodExpiresAt: Date | null;
  readonly storefront: string | null;
  readonly currency: string | null;
  readonly priceMilliunits: number | null;
  readonly revokedAt: Date | null;
};

export type AppleTransactionInput = {
  readonly transactionId: string;
  readonly originalTransactionId: string;
  readonly planId: string | null;
  readonly purchaseDate: Date | null;
  readonly expiresAt: Date | null;
  readonly priceMilliunits: number | null;
  readonly currency: string | null;
  readonly storefront: string | null;
  readonly revokedAt: Date | null;
  /** Apple `revocationReason`: 0 or 1 is a refund; null for family-sharing revokes and live rows. */
  readonly revocationReason: number | null;
};

type ApplePrice = { readonly usd: number; readonly fallback: boolean; readonly paid: boolean };

/**
 * USD for one Apple charge. A missing price counts as the plan's US list
 * price; an unknown currency falls back to the same list price and is
 * counted, so the page can say how much of the figure is a guess.
 */
export function applePriceUsd(
  planId: string,
  priceMilliunits: number | null,
  currency: string | null,
): ApplePrice {
  const listPrice = (APPLE_USD_LIST_PRICE as Readonly<Record<string, number>>)[planId] ?? 0;
  if (priceMilliunits === null) return { usd: listPrice, fallback: true, paid: true };
  if (priceMilliunits <= 0) return { usd: 0, fallback: false, paid: false };
  const converted = toUsd(priceMilliunits / 1000, currency);
  if (converted === null) return { usd: listPrice, fallback: true, paid: true };
  return { usd: roundCents(converted), fallback: false, paid: true };
}

function appleTransactionInterval(
  tx: AppleTransactionInput,
  fallbackPlan: string,
): { interval: CoverageInterval; fallback: boolean } | null {
  if (!tx.purchaseDate || !tx.expiresAt) return null;
  // A refunded or revoked period stops at the revocation, not at its expiry.
  const end = tx.revokedAt && tx.revokedAt < tx.expiresAt ? tx.revokedAt : tx.expiresAt;
  if (end <= tx.purchaseDate) return null;
  const planId = tx.planId ?? fallbackPlan;
  const price = applePriceUsd(planId, tx.priceMilliunits, tx.currency);
  const months = periodMonths(tx.purchaseDate, tx.expiresAt);
  return {
    interval: {
      start: tx.purchaseDate,
      end,
      planId,
      monthlyGrossUsd: roundCents(price.usd / months),
      chargeUsd: price.usd,
      intervalMonths: months,
      paid: price.paid,
      isCharge: true,
    },
    fallback: price.fallback,
  };
}

/** Fallback when the ledger has no usable transaction: the row's own period. */
function appleRowInterval(row: AppleSubscriptionInput): { interval: CoverageInterval; fallback: boolean } | null {
  const start = row.purchaseDate ?? row.originalPurchaseDate;
  if (!start || !row.expiresAt) return null;
  return appleTransactionInterval({
    transactionId: row.originalTransactionId,
    originalTransactionId: row.originalTransactionId,
    planId: row.planId,
    purchaseDate: start,
    expiresAt: row.expiresAt,
    priceMilliunits: row.priceMilliunits,
    currency: row.currency,
    storefront: row.storefront,
    revokedAt: row.revokedAt,
    revocationReason: null,
  }, row.planId);
}

/** Apple keeps access open through the grace period; count it as covered. */
function appleGraceInterval(row: AppleSubscriptionInput, last: CoverageInterval | undefined): CoverageInterval | null {
  if (row.status !== "grace_period" || !row.gracePeriodExpiresAt || !last?.end) return null;
  if (row.gracePeriodExpiresAt <= last.end) return null;
  return { ...last, start: last.end, end: row.gracePeriodExpiresAt, isCharge: false };
}

const APPLE_CURRENT_STATUS: Readonly<Record<string, CurrentStatus>> = {
  active: "active",
  grace_period: "grace_period",
  billing_retry: "billing_issue",
  expired: "inactive",
  revoked: "inactive",
};

export function appleSubscriptionRecord(
  row: AppleSubscriptionInput,
  transactions: readonly AppleTransactionInput[],
): SubscriptionRecord {
  let fxFallbacks = 0;
  const intervals: CoverageInterval[] = [];
  for (const tx of transactions) {
    const built = appleTransactionInterval(tx, row.planId);
    if (!built) continue;
    intervals.push(built.interval);
    if (built.fallback) fxFallbacks += 1;
  }
  if (intervals.length === 0) {
    const built = appleRowInterval(row);
    if (built) {
      intervals.push(built.interval);
      if (built.fallback) fxFallbacks += 1;
    }
  }
  intervals.sort((a, b) => a.start.getTime() - b.start.getTime());
  const grace = appleGraceInterval(row, intervals.at(-1));
  if (grace) intervals.push(grace);
  const base = APPLE_CURRENT_STATUS[row.status] ?? "inactive";
  const lastPaid = intervals.at(-1)?.paid ?? true;
  return {
    source: "apple",
    id: row.originalTransactionId,
    userId: row.userId,
    planId: row.planId,
    environment: appleEnvironment(row.environment),
    currentStatus: base === "active" && !lastPaid ? "trial" : base,
    cancelScheduled: row.autoRenewEnabled === false && base !== "inactive",
    country: row.storefront,
    currency: row.currency,
    intervals,
    endReason: appleEndReason(row.status),
    fxFallbacks,
  };
}

function appleEndReason(status: string): SubscriptionRecord["endReason"] {
  if (status === "revoked") return "revoked";
  if (status === "expired" || status === "billing_retry") return "expired";
  return null;
}

/** Refunds are revoked transactions with a refund reason (0 or 1). */
export function appleRefundEvents(
  row: AppleSubscriptionInput,
  transactions: readonly AppleTransactionInput[],
): RefundEvent[] {
  const refunds: RefundEvent[] = [];
  for (const tx of transactions) {
    if (!tx.revokedAt || (tx.revocationReason !== 0 && tx.revocationReason !== 1)) continue;
    const planId = tx.planId ?? row.planId;
    const price = applePriceUsd(planId, tx.priceMilliunits, tx.currency);
    refunds.push({
      source: "apple",
      id: tx.transactionId,
      subscriptionId: row.originalTransactionId,
      at: tx.revokedAt,
      amountUsd: price.usd,
      planId,
      country: tx.storefront ?? row.storefront,
      environment: appleEnvironment(row.environment),
    });
  }
  return refunds;
}

// ---------------------------------------------------------------- Stripe

export type StripeSubscriptionInput = {
  readonly id: string;
  readonly stackUserId: string;
  readonly status: string;
  readonly plan: string;
  readonly seats: number | null;
  readonly cancelAtPeriodEnd: boolean;
  readonly currentPeriodEnd: Date | null;
  readonly createdAt: Date;
  readonly updatedAt: Date;
  /** Selected fields of the raw Stripe payload (see query.ts). */
  readonly livemode: boolean | null;
  readonly startDate: number | null;
  readonly trialEnd: number | null;
  readonly endedAt: number | null;
  readonly canceledAt: number | null;
  readonly unitAmount: number | null;
  readonly currency: string | null;
  readonly interval: string | null;
  readonly intervalCount: number | null;
  readonly quantity: number | null;
};

/** Stripe statuses that never charged and are not subscriptions yet. */
const STRIPE_SKIPPED_STATUSES = new Set(["incomplete"]);
const STRIPE_ENDED_STATUSES = new Set(["canceled", "incomplete_expired", "unpaid", "paused"]);

const STRIPE_CURRENT_STATUS: Readonly<Record<string, CurrentStatus>> = {
  active: "active",
  trialing: "trial",
  past_due: "billing_issue",
};

function unixDate(seconds: number | null): Date | null {
  return typeof seconds === "number" && Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1000) : null;
}

function stripeEnd(row: StripeSubscriptionInput): Date | null {
  if (!STRIPE_ENDED_STATUSES.has(row.status)) return null;
  return unixDate(row.endedAt) ?? unixDate(row.canceledAt) ?? row.currentPeriodEnd ?? row.updatedAt;
}

function stripeIntervalMonths(row: StripeSubscriptionInput): number {
  const count = row.intervalCount && row.intervalCount > 0 ? row.intervalCount : 1;
  if (row.interval === "year") return 12 * count;
  if (row.interval === "week") return Math.max(count / 4.345, 0.01);
  if (row.interval === "day") return Math.max(count / AVERAGE_MONTH_DAYS, 0.01);
  return count;
}

type StripePrice = { readonly chargeUsd: number; readonly fallback: boolean };

/** Web list price per month (per seat for Team), USD. */
const STRIPE_USD_MONTHLY_LIST_PRICE: Readonly<Record<string, number>> = {
  go: GO_PRICING_USD.month.monthlyEquivalent,
  pro: PRO_PRICING_USD.month.monthlyEquivalent,
  max: MAX_PRICING_USD.month.monthlyEquivalent,
  team: TEAM_PRICING_USD.month.monthlyEquivalent,
};

/**
 * Gross list price of one charge (unit amount times seats), before discounts.
 * A missing unit amount or an unknown currency falls back to the plan's web
 * list price for the period and is counted, like the Apple path, so a paid
 * subscription never adds zero to MRR silently.
 */
export function stripeChargeUsd(row: StripeSubscriptionInput): StripePrice {
  const quantity = Math.max(row.quantity ?? row.seats ?? 1, 1);
  const converted = row.unitAmount === null ? null : toUsd((row.unitAmount / 100) * quantity, row.currency);
  if (converted === null) {
    const listPrice = STRIPE_USD_MONTHLY_LIST_PRICE[row.plan] ?? 0;
    return { chargeUsd: roundCents(listPrice * stripeIntervalMonths(row) * quantity), fallback: true };
  }
  return { chargeUsd: roundCents(converted), fallback: false };
}

/** Null for a row that never became a subscription (status `incomplete`). */
export function stripeSubscriptionRecord(row: StripeSubscriptionInput): SubscriptionRecord | null {
  if (STRIPE_SKIPPED_STATUSES.has(row.status)) return null;
  const start = unixDate(row.startDate) ?? row.createdAt;
  const end = stripeEnd(row);
  const trialEnd = unixDate(row.trialEnd);
  const months = stripeIntervalMonths(row);
  const price = stripeChargeUsd(row);
  const shared = {
    planId: row.plan,
    chargeUsd: price.chargeUsd,
    monthlyGrossUsd: roundCents(price.chargeUsd / months),
    intervalMonths: months,
    isCharge: false,
  };
  const intervals: CoverageInterval[] = [];
  const paidStart = trialEnd && trialEnd > start ? trialEnd : start;
  if (paidStart > start) {
    intervals.push({ ...shared, start, end: end && end < paidStart ? end : paidStart, paid: false });
  }
  if (!end || end > paidStart) intervals.push({ ...shared, start: paidStart, end, paid: true });
  return {
    source: "stripe",
    id: row.id,
    userId: row.stackUserId,
    planId: row.plan,
    environment: row.livemode === false ? "sandbox" : "production",
    currentStatus: STRIPE_CURRENT_STATUS[row.status] ?? "inactive",
    cancelScheduled: row.cancelAtPeriodEnd && !end,
    country: null,
    currency: row.currency ? row.currency.toUpperCase() : null,
    intervals,
    endReason: end ? "canceled" : null,
    fxFallbacks: price.fallback ? 1 : 0,
  };
}

export function roundCents(value: number): number {
  return Math.round(value * 100) / 100;
}
