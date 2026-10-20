// RevenueCat-style subscription metrics over normalized records. Pure and
// deterministic: `now` is an input, so every figure is reproducible in tests.

import type { AnalyticsSource, CoverageInterval, RefundEvent, SubscriptionRecord } from "./records";
import { roundCents } from "./records";

export type Granularity = "day" | "week" | "month";

export type MetricsWindow = {
  readonly from: Date;
  readonly to: Date;
  readonly now: Date;
  readonly granularity: Granularity;
};

const DAY_MS = 24 * 60 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;
/** Renewals land at or a little after expiry; a shorter gap is not churn. */
export const RUN_MERGE_TOLERANCE_MS = DAY_MS;
/** Apple's commission drops from 30% to 15% after one year of paid service. */
export const APPLE_PAID_SERVICE_THRESHOLD_DAYS = 365;
export const APPLE_COMMISSION_FIRST_YEAR = 0.3;
export const APPLE_COMMISSION_AFTER_YEAR = 0.15;
/** Stripe's standard US card pricing; the real fee varies by card and country. */
export const STRIPE_FEE_PERCENT = 0.029;
export const STRIPE_FEE_FIXED_USD = 0.3;
export const MAX_COHORTS = 24;

// ---------------------------------------------------------------- coverage

export type Run = { readonly start: Date; readonly end: Date | null };

const runCache = new WeakMap<SubscriptionRecord, Run[]>();

/** Contiguous paid coverage, merging renewals that land within the tolerance. */
export function paidRuns(record: SubscriptionRecord): Run[] {
  const cached = runCache.get(record);
  if (cached) return cached;
  const runs: Array<{ start: Date; end: Date | null }> = [];
  for (const interval of record.intervals) {
    if (!interval.paid) continue;
    const last = runs.at(-1);
    if (last && (last.end === null || interval.start.getTime() - last.end.getTime() <= RUN_MERGE_TOLERANCE_MS)) {
      last.end = laterEnd(last.end, interval.end);
      continue;
    }
    runs.push({ start: interval.start, end: interval.end });
  }
  runCache.set(record, runs);
  return runs;
}

function laterEnd(a: Date | null, b: Date | null): Date | null {
  if (a === null || b === null) return null;
  return a > b ? a : b;
}

function covers(run: { start: Date; end: Date | null }, at: Date): boolean {
  return run.start <= at && (run.end === null || at < run.end);
}

export function isActiveAt(record: SubscriptionRecord, at: Date): boolean {
  return paidRuns(record).some((run) => covers(run, at));
}

/** The paid interval billing `at`: the newest one started by then, if `at` is covered. */
export function paidIntervalAt(record: SubscriptionRecord, at: Date): CoverageInterval | null {
  if (!isActiveAt(record, at)) return null;
  let found: CoverageInterval | null = null;
  for (const interval of record.intervals) {
    if (interval.paid && interval.start <= at) found = interval;
  }
  return found;
}

export function isTrialAt(record: SubscriptionRecord, at: Date): boolean {
  if (isActiveAt(record, at)) return false;
  return record.intervals.some((interval) => !interval.paid && covers(interval, at));
}

export function firstPaidStart(record: SubscriptionRecord): Date | null {
  return paidRuns(record)[0]?.start ?? null;
}

// ---------------------------------------------------------------- revenue

/** Days of paid, charged service before `at` (grace periods are not paid service). */
export function paidServiceDays(record: SubscriptionRecord, at: Date): number {
  let ms = 0;
  for (const interval of record.intervals) {
    if (!interval.paid || !interval.isCharge || interval.start >= at) continue;
    const end = interval.end && interval.end < at ? interval.end : at;
    ms += Math.max(0, end.getTime() - interval.start.getTime());
  }
  return ms / DAY_MS;
}

export function appleCommissionRate(record: SubscriptionRecord, at: Date): number {
  return paidServiceDays(record, at) >= APPLE_PAID_SERVICE_THRESHOLD_DAYS
    ? APPLE_COMMISSION_AFTER_YEAR
    : APPLE_COMMISSION_FIRST_YEAR;
}

/** Stripe processing estimate: 2.9% plus 30c per charge, spread over the period. */
export function stripeNetMonthlyUsd(interval: CoverageInterval): number {
  const fixedPerMonth = STRIPE_FEE_FIXED_USD / Math.max(interval.intervalMonths, 0.01);
  if (interval.monthlyGrossUsd <= 0) return 0;
  return Math.max(0, roundCents(interval.monthlyGrossUsd * (1 - STRIPE_FEE_PERCENT) - fixedPerMonth));
}

export function netMonthlyUsd(record: SubscriptionRecord, interval: CoverageInterval, at: Date): number {
  if (record.source === "stripe") return stripeNetMonthlyUsd(interval);
  return roundCents(interval.monthlyGrossUsd * (1 - appleCommissionRate(record, at)));
}

export type MrrPoint = { readonly grossUsd: number; readonly netUsd: number; readonly active: number };

export function mrrAt(records: readonly SubscriptionRecord[], at: Date): MrrPoint {
  let grossUsd = 0;
  let netUsd = 0;
  let active = 0;
  for (const record of records) {
    const interval = paidIntervalAt(record, at);
    if (!interval) continue;
    active += 1;
    grossUsd += interval.monthlyGrossUsd;
    netUsd += netMonthlyUsd(record, interval, at);
  }
  return { grossUsd: roundCents(grossUsd), netUsd: roundCents(netUsd), active };
}

// ---------------------------------------------------------------- lifecycle

export type LifecycleEvent = {
  readonly kind: "new" | "reactivated" | "churned";
  readonly at: Date;
  readonly record: SubscriptionRecord;
  readonly reason?: "expired" | "revoked" | "canceled";
};

/** New, reactivation, and churn moments that have happened by `now`. */
export function lifecycleEvents(record: SubscriptionRecord, now: Date): LifecycleEvent[] {
  const runs = paidRuns(record);
  const events: LifecycleEvent[] = [];
  runs.forEach((run, index) => {
    if (run.start <= now) events.push({ kind: index === 0 ? "new" : "reactivated", at: run.start, record });
    if (run.end && run.end <= now) {
      const isLast = index === runs.length - 1;
      events.push({ kind: "churned", at: run.end, record, reason: isLast ? record.endReason ?? "expired" : "expired" });
    }
  });
  return events;
}

/** Churned during the window over active at its start; null when nothing was active. */
export function churnRate(churned: number, activeAtStart: number): number | null {
  return activeAtStart > 0 ? churned / activeAtStart : null;
}

// ---------------------------------------------------------------- buckets

export type Bucket = { readonly start: Date; readonly end: Date };

export function bucketStart(at: Date, granularity: Granularity): Date {
  const day = new Date(Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), at.getUTCDate()));
  if (granularity === "day") return day;
  if (granularity === "month") return new Date(Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), 1));
  const mondayOffset = (day.getUTCDay() + 6) % 7;
  return new Date(day.getTime() - mondayOffset * DAY_MS);
}

export function nextBucketStart(start: Date, granularity: Granularity): Date {
  if (granularity === "day") return new Date(start.getTime() + DAY_MS);
  if (granularity === "week") return new Date(start.getTime() + 7 * DAY_MS);
  return new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, 1));
}

export function buckets(from: Date, to: Date, granularity: Granularity): Bucket[] {
  const result: Bucket[] = [];
  for (let start = bucketStart(from, granularity); start <= to; start = nextBucketStart(start, granularity)) {
    result.push({ start, end: nextBucketStart(start, granularity) });
  }
  return result;
}

export function addUtcMonths(date: Date, months: number): Date {
  const result = new Date(date.getTime());
  const day = result.getUTCDate();
  result.setUTCDate(1);
  result.setUTCMonth(result.getUTCMonth() + months);
  const lastDay = new Date(Date.UTC(result.getUTCFullYear(), result.getUTCMonth() + 1, 0)).getUTCDate();
  result.setUTCDate(Math.min(day, lastDay));
  return result;
}

function monthKey(date: Date): string {
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

// ---------------------------------------------------------------- cohorts

export type CohortRow = {
  /** `YYYY-MM` of the first paid period. */
  readonly cohort: string;
  readonly size: number;
  /** Share still paying N months after their own start; null when month N has not arrived for anyone. */
  readonly retention: readonly (number | null)[];
};

/**
 * Monthly cohorts by first paid month. Month N checks each member at their
 * own start plus N months (plus 12 hours, so a renewal at the exact
 * boundary counts), the way RevenueCat measures subscription retention.
 */
export function cohortRetention(
  records: readonly SubscriptionRecord[],
  window: Pick<MetricsWindow, "from" | "to" | "now">,
): CohortRow[] {
  const fromMonth = bucketStart(window.from, "month");
  const groups = new Map<string, Array<{ record: SubscriptionRecord; start: Date }>>();
  for (const record of records) {
    const start = firstPaidStart(record);
    if (!start || start < fromMonth || start > window.to || start > window.now) continue;
    const key = monthKey(start);
    const group = groups.get(key) ?? [];
    group.push({ record, start });
    groups.set(key, group);
  }
  const keys = [...groups.keys()].sort().slice(-MAX_COHORTS);
  return keys.map((key) => cohortRow(key, groups.get(key) ?? [], window.now));
}

function cohortRow(
  cohort: string,
  members: Readonly<Array<{ record: SubscriptionRecord; start: Date }>>,
  now: Date,
): CohortRow {
  const retention: Array<number | null> = [];
  for (let month = 0; ; month += 1) {
    let eligible = 0;
    let retained = 0;
    for (const { record, start } of members) {
      const at = month === 0 ? start : new Date(addUtcMonths(start, month).getTime() + 12 * HOUR_MS);
      if (at > now) continue;
      eligible += 1;
      if (isActiveAt(record, at)) retained += 1;
    }
    if (eligible === 0) break;
    retention.push(month === 0 ? 1 : retained / eligible);
  }
  return { cohort, size: members.length, retention };
}

// ---------------------------------------------------------------- report

export type SourceSummary = {
  readonly active: number;
  readonly mrrGrossUsd: number;
  readonly mrrNetUsd: number;
};

export type SeriesPoint = {
  readonly start: string;
  readonly end: string;
  readonly mrrGrossUsd: number;
  readonly mrrNetUsd: number;
  readonly active: number;
  readonly newSubscriptions: number;
  readonly reactivations: number;
  readonly churned: number;
};

export type PlanMixRow = {
  readonly planId: string;
  readonly active: number;
  readonly mrrGrossUsd: number;
  readonly share: number;
};

export type StorefrontRow = {
  /** ISO 3166 alpha-3 storefront, `UNKNOWN`, or `STRIPE` (no country on file). */
  readonly country: string;
  readonly active: number;
  readonly mrrGrossUsd: number;
  /** Charges collected in the window (Apple only; the Stripe mirror keeps no invoices). */
  readonly revenueGrossUsd: number;
  readonly refundsUsd: number;
};

export type SubscriptionMetrics = {
  readonly asOf: string;
  readonly window: { readonly from: string; readonly to: string; readonly granularity: Granularity };
  readonly kpis: {
    readonly activeSubscriptions: number;
    readonly activeTrials: number;
    readonly mrrGrossUsd: number;
    readonly mrrNetUsd: number;
    readonly newSubscriptions: number;
    readonly reactivations: number;
    readonly churned: number;
    readonly churnedByReason: Readonly<Record<"expired" | "revoked" | "canceled", number>>;
    readonly activeAtWindowStart: number;
    readonly churnRate: number | null;
    readonly refunds: { readonly count: number; readonly amountUsd: number };
    readonly billingIssue: number;
    readonly gracePeriod: number;
    readonly cancelScheduled: number;
    readonly fxFallbacks: number;
  };
  readonly bySource: Readonly<Record<AnalyticsSource, SourceSummary>>;
  readonly series: readonly SeriesPoint[];
  readonly planMix: readonly PlanMixRow[];
  readonly storefronts: readonly StorefrontRow[];
  readonly cohorts: readonly CohortRow[];
};

function inWindow(at: Date, window: MetricsWindow): boolean {
  return at >= window.from && at <= window.to && at <= window.now;
}

function asOfFor(window: MetricsWindow): Date {
  return window.to < window.now ? window.to : window.now;
}

/** Status counts describe today: Apple and Stripe only report current state. */
function currentStateCounts(records: readonly SubscriptionRecord[]) {
  let billingIssue = 0;
  let gracePeriod = 0;
  let cancelScheduled = 0;
  for (const record of records) {
    if (record.currentStatus === "billing_issue") billingIssue += 1;
    if (record.currentStatus === "grace_period") gracePeriod += 1;
    if (record.cancelScheduled) cancelScheduled += 1;
  }
  return { billingIssue, gracePeriod, cancelScheduled };
}

function sourceSummaries(records: readonly SubscriptionRecord[], at: Date): Record<AnalyticsSource, SourceSummary> {
  const summary = (source: AnalyticsSource): SourceSummary => {
    const point = mrrAt(records.filter((record) => record.source === source), at);
    return { active: point.active, mrrGrossUsd: point.grossUsd, mrrNetUsd: point.netUsd };
  };
  return { apple: summary("apple"), stripe: summary("stripe") };
}

function seriesFor(
  records: readonly SubscriptionRecord[],
  events: readonly LifecycleEvent[],
  window: MetricsWindow,
): SeriesPoint[] {
  return buckets(window.from, asOfFor(window), window.granularity).map((bucket) => {
    const sampleAt = new Date(Math.min(bucket.end.getTime(), window.now.getTime()) - 1);
    const point = mrrAt(records, sampleAt);
    const inBucket = events.filter((event) => event.at >= bucket.start && event.at < bucket.end);
    return {
      start: bucket.start.toISOString(),
      end: bucket.end.toISOString(),
      mrrGrossUsd: point.grossUsd,
      mrrNetUsd: point.netUsd,
      active: point.active,
      newSubscriptions: inBucket.filter((event) => event.kind === "new").length,
      reactivations: inBucket.filter((event) => event.kind === "reactivated").length,
      churned: inBucket.filter((event) => event.kind === "churned").length,
    };
  });
}

export function planMix(records: readonly SubscriptionRecord[], at: Date): PlanMixRow[] {
  const rows = new Map<string, { active: number; mrr: number }>();
  let total = 0;
  for (const record of records) {
    const interval = paidIntervalAt(record, at);
    if (!interval) continue;
    const row = rows.get(interval.planId) ?? { active: 0, mrr: 0 };
    row.active += 1;
    row.mrr += interval.monthlyGrossUsd;
    rows.set(interval.planId, row);
    total += 1;
  }
  return [...rows.entries()]
    .map(([planId, row]) => ({
      planId,
      active: row.active,
      mrrGrossUsd: roundCents(row.mrr),
      share: total > 0 ? row.active / total : 0,
    }))
    .sort((a, b) => b.mrrGrossUsd - a.mrrGrossUsd || b.active - a.active);
}

type StorefrontAccumulator = { active: number; mrr: number; revenue: number; refunds: number };

function storefrontKey(record: Pick<SubscriptionRecord, "source" | "country">): string {
  if (record.source === "stripe") return "STRIPE";
  return record.country?.trim().toUpperCase() || "UNKNOWN";
}

export function storefronts(
  records: readonly SubscriptionRecord[],
  refunds: readonly RefundEvent[],
  window: MetricsWindow,
): StorefrontRow[] {
  const at = asOfFor(window);
  const rows = new Map<string, StorefrontAccumulator>();
  const row = (key: string) => {
    const existing = rows.get(key);
    if (existing) return existing;
    const created = { active: 0, mrr: 0, revenue: 0, refunds: 0 };
    rows.set(key, created);
    return created;
  };
  for (const record of records) {
    const key = storefrontKey(record);
    const interval = paidIntervalAt(record, at);
    if (interval) {
      row(key).active += 1;
      row(key).mrr += interval.monthlyGrossUsd;
    }
    for (const charge of record.intervals) {
      if (charge.isCharge && charge.paid && inWindow(charge.start, window)) row(key).revenue += charge.chargeUsd;
    }
  }
  for (const refund of refunds) {
    if (inWindow(refund.at, window)) row(storefrontKey(refund)).refunds += refund.amountUsd;
  }
  return [...rows.entries()]
    .map(([country, value]) => ({
      country,
      active: value.active,
      mrrGrossUsd: roundCents(value.mrr),
      revenueGrossUsd: roundCents(value.revenue),
      refundsUsd: roundCents(value.refunds),
    }))
    .filter((value) => value.active > 0 || value.revenueGrossUsd > 0 || value.refundsUsd > 0)
    .sort((a, b) => b.mrrGrossUsd - a.mrrGrossUsd || b.revenueGrossUsd - a.revenueGrossUsd);
}

export function computeSubscriptionMetrics(
  records: readonly SubscriptionRecord[],
  refunds: readonly RefundEvent[],
  window: MetricsWindow,
): SubscriptionMetrics {
  const asOf = asOfFor(window);
  const current = mrrAt(records, asOf);
  const events = records.flatMap((record) => lifecycleEvents(record, window.now));
  const windowEvents = events.filter((event) => inWindow(event.at, window));
  const churnedEvents = windowEvents.filter((event) => event.kind === "churned");
  const churnedByReason = { expired: 0, revoked: 0, canceled: 0 };
  for (const event of churnedEvents) churnedByReason[event.reason ?? "expired"] += 1;
  const activeAtWindowStart = mrrAt(records, window.from).active;
  const windowRefunds = refunds.filter((refund) => inWindow(refund.at, window));
  return {
    asOf: asOf.toISOString(),
    window: { from: window.from.toISOString(), to: window.to.toISOString(), granularity: window.granularity },
    kpis: {
      activeSubscriptions: current.active,
      activeTrials: records.filter((record) => isTrialAt(record, asOf)).length,
      mrrGrossUsd: current.grossUsd,
      mrrNetUsd: current.netUsd,
      newSubscriptions: windowEvents.filter((event) => event.kind === "new").length,
      reactivations: windowEvents.filter((event) => event.kind === "reactivated").length,
      churned: churnedEvents.length,
      churnedByReason,
      activeAtWindowStart,
      churnRate: churnRate(churnedEvents.length, activeAtWindowStart),
      refunds: {
        count: windowRefunds.length,
        amountUsd: roundCents(windowRefunds.reduce((sum, refund) => sum + refund.amountUsd, 0)),
      },
      ...currentStateCounts(records),
      fxFallbacks: records.reduce((sum, record) => sum + record.fxFallbacks, 0),
    },
    bySource: sourceSummaries(records, asOf),
    series: seriesFor(records, events, window),
    planMix: planMix(records, asOf),
    storefronts: storefronts(records, refunds, window),
    cohorts: cohortRetention(records, window),
  };
}
