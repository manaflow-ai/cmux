// Query layer for subscription analytics: parses the admin filters, reads
// the Apple ledger and the Stripe subscription mirror, and assembles the
// report from the pure functions in records.ts and metrics.ts.
//
// Reads are whole-table scans of three small subscription tables (one row
// per subscription or per billing period), selecting only the columns the
// metrics use. The raw Stripe payload is projected to a handful of JSON
// fields in SQL so the jsonb blobs never leave the database.

import { and, desc, eq, gte, lte, ne, sql, type SQL, type SQLWrapper } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import {
  appleNotifications,
  appleSubscriptions,
  appleTransactions,
  stripeSubscriptions,
} from "../../../db/schema";
import { FX_RATES_AS_OF } from "./fx";
import {
  computeSubscriptionMetrics,
  type Granularity,
  type SubscriptionMetrics,
  STRIPE_FEE_FIXED_USD,
  STRIPE_FEE_PERCENT,
} from "./metrics";
import {
  appleEnvironment,
  appleRefundEvents,
  applePriceUsd,
  appleSubscriptionRecord,
  stripeSubscriptionRecord,
  type AnalyticsEnvironment,
  type AnalyticsSource,
  type AppleSubscriptionInput,
  type AppleTransactionInput,
  type RefundEvent,
  type StripeSubscriptionInput,
  type SubscriptionRecord,
} from "./records";

// ---------------------------------------------------------------- filters

export type AnalyticsQuery = {
  readonly source: AnalyticsSource | "all";
  readonly plan: string | null;
  readonly environment: AnalyticsEnvironment | "all";
  readonly from: Date;
  readonly to: Date;
  readonly granularity: Granularity;
};

const DAY_MS = 24 * 60 * 60 * 1000;
export const DEFAULT_RANGE_DAYS = 180;
export const MAX_RANGE_DAYS = 3 * 366;
/** Upper bound on chart points, so a day-granularity multi-year query is refused. */
export const MAX_SERIES_POINTS = 400;
const POINTS_PER_DAY: Readonly<Record<Granularity, number>> = { day: 1, week: 1 / 7, month: 1 / 28 };
const PLAN_PATTERN = /^[a-z][a-z0-9_-]{0,31}$/;

type SearchParamsLike = { get(name: string): string | null };

function oneOf<T extends string>(value: string | null, allowed: readonly T[], fallback: T): T | null {
  if (value === null || value === "") return fallback;
  return (allowed as readonly string[]).includes(value) ? (value as T) : null;
}

function parseDate(value: string | null, fallback: Date): Date | null {
  if (value === null || value === "") return fallback;
  // Date-only values cover the whole UTC day they name.
  const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(value);
  const parsed = new Date(dateOnly ? `${value}T00:00:00.000Z` : value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function parsePlan(value: string | null): string | null | undefined {
  if (value === null || value === "" || value === "all") return null;
  const plan = value.trim().toLowerCase();
  return PLAN_PATTERN.test(plan) ? plan : undefined;
}

/**
 * Admin filters from the query string. Defaults: every source, every plan,
 * production only, the last 180 days by week. Null for any invalid value.
 */
export function parseAnalyticsQuery(params: SearchParamsLike, now: Date): AnalyticsQuery | null {
  const source = oneOf<AnalyticsSource | "all">(params.get("source"), ["apple", "stripe", "all"], "all");
  const environment = oneOf<AnalyticsEnvironment | "all">(
    params.get("environment"),
    ["production", "sandbox", "all"],
    "production",
  );
  const granularity = oneOf<Granularity>(params.get("granularity"), ["day", "week", "month"], "week");
  const plan = parsePlan(params.get("plan"));
  const to = parseDate(params.get("to"), now);
  const from = to ? parseDate(params.get("from"), new Date(to.getTime() - DEFAULT_RANGE_DAYS * DAY_MS)) : null;
  if (!source || !environment || !granularity || plan === undefined || !to || !from) return null;
  const toEnd = /^\d{4}-\d{2}-\d{2}$/.test(params.get("to") ?? "") ? new Date(to.getTime() + DAY_MS - 1) : to;
  const days = (toEnd.getTime() - from.getTime()) / DAY_MS;
  if (days <= 0 || days > MAX_RANGE_DAYS) return null;
  if (days * POINTS_PER_DAY[granularity] > MAX_SERIES_POINTS) return null;
  return { source, plan, environment, from, to: toEnd, granularity };
}

// ---------------------------------------------------------------- inputs

export type RecentEventInput = {
  readonly notificationUuid: string;
  readonly notificationType: string;
  readonly subtype: string | null;
  readonly environment: string;
  readonly signedDate: Date;
  readonly processedAt: Date | null;
  readonly error: string | null;
  readonly originalTransactionId: string | null;
  readonly userId: string | null;
  readonly planId: string | null;
  readonly productId: string | null;
  readonly priceMilliunits: number | null;
  readonly currency: string | null;
  readonly storefront: string | null;
};

export type AnalyticsInputs = {
  readonly appleSubscriptions: readonly AppleSubscriptionInput[];
  readonly appleTransactions: readonly AppleTransactionInput[];
  readonly stripeSubscriptions: readonly StripeSubscriptionInput[];
  readonly recentEvents: readonly RecentEventInput[];
};

export const RECENT_EVENTS_LIMIT = 50;

type Db = ReturnType<typeof cloudDb>;

function appleEnvironmentFilter(column: SQLWrapper, environment: AnalyticsQuery["environment"]): SQL | undefined {
  if (environment === "production") return eq(column, "Production");
  if (environment === "sandbox") return ne(column, "Production");
  return undefined;
}

function stripeEnvironmentFilter(environment: AnalyticsQuery["environment"]): SQL | undefined {
  const live = sql`coalesce((${stripeSubscriptions.raw}->>'livemode')::boolean, true)`;
  if (environment === "production") return sql`${live} = true`;
  if (environment === "sandbox") return sql`${live} = false`;
  return undefined;
}

const stripePrice = sql`(${stripeSubscriptions.raw}->'items'->'data'->0->'price')`;
const stripeItem = sql`(${stripeSubscriptions.raw}->'items'->'data'->0)`;

function rawNumber(expression: SQL): SQL<number | null> {
  return sql<number | null>`nullif(${expression}, '')::float8`;
}

async function loadApple(db: Db, query: AnalyticsQuery) {
  if (query.source === "stripe") return { subscriptions: [], transactions: [] };
  const subscriptions = await db
    .select({
      originalTransactionId: appleSubscriptions.originalTransactionId,
      userId: appleSubscriptions.userId,
      environment: appleSubscriptions.environment,
      planId: appleSubscriptions.planId,
      status: appleSubscriptions.status,
      autoRenewEnabled: appleSubscriptions.autoRenewEnabled,
      purchaseDate: appleSubscriptions.purchaseDate,
      originalPurchaseDate: appleSubscriptions.originalPurchaseDate,
      expiresAt: appleSubscriptions.expiresAt,
      gracePeriodExpiresAt: appleSubscriptions.gracePeriodExpiresAt,
      storefront: appleSubscriptions.storefront,
      currency: appleSubscriptions.currency,
      priceMilliunits: appleSubscriptions.priceMilliunits,
      revokedAt: appleSubscriptions.revokedAt,
    })
    .from(appleSubscriptions)
    .where(appleEnvironmentFilter(appleSubscriptions.environment, query.environment));
  const transactions = await db
    .select({
      transactionId: appleTransactions.transactionId,
      originalTransactionId: appleTransactions.originalTransactionId,
      planId: appleTransactions.planId,
      purchaseDate: appleTransactions.purchaseDate,
      expiresAt: appleTransactions.expiresAt,
      priceMilliunits: appleTransactions.priceMilliunits,
      currency: appleTransactions.currency,
      storefront: appleTransactions.storefront,
      revokedAt: appleTransactions.revokedAt,
      revocationReason: sql<number | null>`nullif(${appleTransactions.payload}->>'revocationReason', '')::int`,
    })
    .from(appleTransactions)
    .where(appleEnvironmentFilter(appleTransactions.environment, query.environment));
  return { subscriptions, transactions };
}

async function loadStripe(db: Db, query: AnalyticsQuery): Promise<StripeSubscriptionInput[]> {
  if (query.source === "apple") return [];
  return db
    .select({
      id: stripeSubscriptions.id,
      stackUserId: stripeSubscriptions.stackUserId,
      status: stripeSubscriptions.status,
      plan: stripeSubscriptions.plan,
      seats: stripeSubscriptions.seats,
      cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      createdAt: stripeSubscriptions.createdAt,
      updatedAt: stripeSubscriptions.updatedAt,
      livemode: sql<boolean | null>`(${stripeSubscriptions.raw}->>'livemode')::boolean`,
      startDate: rawNumber(sql`${stripeSubscriptions.raw}->>'start_date'`),
      trialEnd: rawNumber(sql`${stripeSubscriptions.raw}->>'trial_end'`),
      endedAt: rawNumber(sql`${stripeSubscriptions.raw}->>'ended_at'`),
      canceledAt: rawNumber(sql`${stripeSubscriptions.raw}->>'canceled_at'`),
      unitAmount: rawNumber(sql`${stripePrice}->>'unit_amount'`),
      currency: sql<string | null>`${stripePrice}->>'currency'`,
      interval: sql<string | null>`${stripePrice}->'recurring'->>'interval'`,
      intervalCount: rawNumber(sql`${stripePrice}->'recurring'->>'interval_count'`),
      quantity: rawNumber(sql`${stripeItem}->>'quantity'`),
    })
    .from(stripeSubscriptions)
    .where(stripeEnvironmentFilter(query.environment));
}

const transactionInfo = sql`(${appleNotifications.payload}->'data'->'transactionInfo')`;

async function loadRecentEvents(db: Db, query: AnalyticsQuery): Promise<RecentEventInput[]> {
  if (query.source === "stripe") return [];
  return db
    .select({
      notificationUuid: appleNotifications.notificationUuid,
      notificationType: appleNotifications.notificationType,
      subtype: appleNotifications.subtype,
      environment: appleNotifications.environment,
      signedDate: appleNotifications.signedDate,
      processedAt: appleNotifications.processedAt,
      error: appleNotifications.error,
      originalTransactionId: appleNotifications.originalTransactionId,
      userId: appleSubscriptions.userId,
      planId: appleSubscriptions.planId,
      productId: sql<string | null>`${transactionInfo}->>'productId'`,
      priceMilliunits: rawNumber(sql`${transactionInfo}->>'price'`),
      currency: sql<string | null>`${transactionInfo}->>'currency'`,
      storefront: sql<string | null>`${transactionInfo}->>'storefront'`,
    })
    .from(appleNotifications)
    .leftJoin(
      appleSubscriptions,
      eq(appleSubscriptions.originalTransactionId, appleNotifications.originalTransactionId),
    )
    .where(and(
      appleEnvironmentFilter(appleNotifications.environment, query.environment),
      gte(appleNotifications.signedDate, query.from),
      lte(appleNotifications.signedDate, query.to),
    ))
    .orderBy(desc(appleNotifications.signedDate))
    // Over-read so a plan filter applied after the join still fills the list.
    .limit(query.plan ? RECENT_EVENTS_LIMIT * 4 : RECENT_EVENTS_LIMIT);
}

export async function loadAnalyticsInputs(query: AnalyticsQuery, db: Db = cloudDb()): Promise<AnalyticsInputs> {
  const [apple, stripe, recentEvents] = await Promise.all([
    loadApple(db, query),
    loadStripe(db, query),
    loadRecentEvents(db, query),
  ]);
  return {
    appleSubscriptions: apple.subscriptions,
    appleTransactions: apple.transactions,
    stripeSubscriptions: stripe,
    recentEvents,
  };
}

// ---------------------------------------------------------------- report

export type RecentEvent = {
  readonly id: string;
  readonly at: string;
  readonly type: string;
  readonly subtype: string | null;
  readonly environment: AnalyticsEnvironment;
  readonly userId: string | null;
  readonly planId: string | null;
  readonly productId: string | null;
  readonly price: number | null;
  readonly currency: string | null;
  readonly priceUsdEstimate: number | null;
  readonly storefront: string | null;
  /** `processed`, `pending`, or the ledger's error (e.g. `unlinked_account`). */
  readonly status: string;
};

export type SubscriptionAnalyticsReport = SubscriptionMetrics & {
  readonly filters: {
    readonly source: AnalyticsQuery["source"];
    readonly plan: string | null;
    readonly environment: AnalyticsQuery["environment"];
  };
  readonly plans: readonly string[];
  readonly recentEvents: readonly RecentEvent[];
  readonly methodology: {
    readonly fxRatesAsOf: string;
    readonly appleNet: string;
    readonly stripeNet: string;
    readonly stripeCoverage: string;
    readonly statusCounts: string;
  };
};

/** `<bundle>.<plan>.monthly` names its plan; anything else has none. */
function planFromProductId(productId: string | null): string | null {
  const parts = productId?.split(".") ?? [];
  return parts.length >= 3 ? parts[parts.length - 2] ?? null : null;
}

function recentEvent(input: RecentEventInput): RecentEvent {
  const planId = input.planId ?? planFromProductId(input.productId);
  const price = input.priceMilliunits === null ? null : input.priceMilliunits / 1000;
  const usd = planId && input.priceMilliunits !== null
    ? applePriceUsd(planId, input.priceMilliunits, input.currency).usd
    : null;
  return {
    id: input.notificationUuid,
    at: input.signedDate.toISOString(),
    type: input.notificationType,
    subtype: input.subtype,
    environment: appleEnvironment(input.environment),
    userId: input.userId,
    planId,
    productId: input.productId,
    price,
    currency: input.currency,
    priceUsdEstimate: usd,
    storefront: input.storefront,
    status: input.processedAt ? input.error ?? "processed" : "pending",
  };
}

function groupTransactions(transactions: readonly AppleTransactionInput[]): Map<string, AppleTransactionInput[]> {
  const byOriginal = new Map<string, AppleTransactionInput[]>();
  for (const tx of transactions) {
    const list = byOriginal.get(tx.originalTransactionId) ?? [];
    list.push(tx);
    byOriginal.set(tx.originalTransactionId, list);
  }
  return byOriginal;
}

/** Normalized records and refunds for every row, before the plan and source filters. */
export function analyticsRecords(inputs: AnalyticsInputs): { records: SubscriptionRecord[]; refunds: RefundEvent[] } {
  const byOriginal = groupTransactions(inputs.appleTransactions);
  const records: SubscriptionRecord[] = [];
  const refunds: RefundEvent[] = [];
  for (const row of inputs.appleSubscriptions) {
    const transactions = byOriginal.get(row.originalTransactionId) ?? [];
    records.push(appleSubscriptionRecord(row, transactions));
    refunds.push(...appleRefundEvents(row, transactions));
  }
  for (const row of inputs.stripeSubscriptions) {
    const record = stripeSubscriptionRecord(row);
    if (record) records.push(record);
  }
  return { records, refunds };
}

function matches(
  item: { source: AnalyticsSource; environment: AnalyticsEnvironment; planId: string | null },
  query: AnalyticsQuery,
): boolean {
  if (query.source !== "all" && item.source !== query.source) return false;
  if (query.environment !== "all" && item.environment !== query.environment) return false;
  return query.plan === null || item.planId === query.plan;
}

export const ANALYTICS_METHODOLOGY: SubscriptionAnalyticsReport["methodology"] = {
  fxRatesAsOf: FX_RATES_AS_OF,
  appleNet: "Apple net = gross x 70%, or 85% once the subscription has 365 days of paid service. "
    + "Gross is the storefront price converted to USD with a static rate table and still includes VAT/GST where Apple charges it.",
  stripeNet: `Stripe net is an ESTIMATE: list price x (1 - ${STRIPE_FEE_PERCENT * 100}%) - $${STRIPE_FEE_FIXED_USD.toFixed(2)} per charge. `
    + "Coupons, taxes, and international card fees are not reflected.",
  stripeCoverage: "Stripe comes from the local stripe_subscriptions mirror: active subscriptions, MRR, plan mix, new, churn, "
    + "scheduled cancels, and past_due are covered; refunds and collected revenue are not (no invoice or charge mirror), "
    + "Stripe has no storefront country, and its history is one period per subscription at its current price.",
  statusCounts: "Billing issue, grace period, and auto-renew-off counts describe current state, not the date range.",
};

export function buildAnalyticsReport(
  inputs: AnalyticsInputs,
  query: AnalyticsQuery,
  now: Date,
): SubscriptionAnalyticsReport {
  const { records, refunds } = analyticsRecords(inputs);
  const plans = [...new Set(records.map((record) => record.planId))].sort();
  const filtered = records.filter((record) => matches(record, query));
  const filteredRefunds = refunds.filter((refund) => matches(refund, query));
  const metrics = computeSubscriptionMetrics(filtered, filteredRefunds, {
    from: query.from,
    to: query.to,
    now,
    granularity: query.granularity,
  });
  const recentEvents = inputs.recentEvents
    .map(recentEvent)
    .filter((event) => matches({ ...event, source: "apple" }, query))
    .slice(0, RECENT_EVENTS_LIMIT);
  return {
    ...metrics,
    filters: { source: query.source, plan: query.plan, environment: query.environment },
    plans,
    recentEvents,
    methodology: ANALYTICS_METHODOLOGY,
  };
}

export type SubscriptionAnalyticsLoader = (query: AnalyticsQuery, now: Date) => Promise<SubscriptionAnalyticsReport>;

export const loadSubscriptionAnalytics: SubscriptionAnalyticsLoader = async (query, now) =>
  buildAnalyticsReport(await loadAnalyticsInputs(query), query, now);
