import { describe, expect, test } from "bun:test";

import { toUsd, USD_PER_UNIT } from "../services/billing/analytics/fx";
import {
  addUtcMonths,
  appleCommissionRate,
  buckets,
  churnRate,
  cohortRetention,
  computeSubscriptionMetrics,
  isActiveAt,
  mrrAt,
  stripeNetMonthlyUsd,
} from "../services/billing/analytics/metrics";
import { buildAnalyticsReport, parseAnalyticsQuery, type AnalyticsInputs } from "../services/billing/analytics/query";
import {
  applePriceUsd,
  appleRefundEvents,
  appleSubscriptionRecord,
  stripeSubscriptionRecord,
  type AppleSubscriptionInput,
  type AppleTransactionInput,
  type StripeSubscriptionInput,
} from "../services/billing/analytics/records";

const d = (value: string) => new Date(value);

function appleRow(overrides: Partial<AppleSubscriptionInput> & { originalTransactionId: string }): AppleSubscriptionInput {
  return {
    userId: `user-${overrides.originalTransactionId}`,
    environment: "Production",
    planId: "pro",
    status: "expired",
    autoRenewEnabled: true,
    purchaseDate: null,
    originalPurchaseDate: null,
    expiresAt: null,
    gracePeriodExpiresAt: null,
    storefront: "USA",
    currency: "USD",
    priceMilliunits: 10_000,
    revokedAt: null,
    ...overrides,
  };
}

/** `count` consecutive monthly USD transactions starting at `start`. */
function monthlyTransactions(
  originalTransactionId: string,
  start: Date,
  count: number,
  overrides: Partial<AppleTransactionInput> = {},
): AppleTransactionInput[] {
  return Array.from({ length: count }, (_, index) => ({
    transactionId: `${originalTransactionId}-${index}`,
    originalTransactionId,
    planId: "pro",
    purchaseDate: addUtcMonths(start, index),
    expiresAt: addUtcMonths(start, index + 1),
    priceMilliunits: 10_000,
    currency: "USD",
    storefront: "USA",
    revokedAt: null,
    revocationReason: null,
    ...overrides,
  }));
}

function stripeRow(overrides: Partial<StripeSubscriptionInput> & { id: string }): StripeSubscriptionInput {
  return {
    stackUserId: `user-${overrides.id}`,
    status: "active",
    plan: "pro",
    seats: null,
    cancelAtPeriodEnd: false,
    currentPeriodEnd: null,
    createdAt: d("2026-01-01T00:00:00Z"),
    updatedAt: d("2026-01-01T00:00:00Z"),
    livemode: true,
    startDate: Date.parse("2026-01-01T00:00:00Z") / 1000,
    trialEnd: null,
    endedAt: null,
    canceledAt: null,
    unitAmount: 5000,
    currency: "usd",
    interval: "month",
    intervalCount: 1,
    quantity: 1,
    ...overrides,
  };
}

describe("FX", () => {
  test("converts listed currencies and refuses unknown ones", () => {
    expect(toUsd(10, "USD")).toBe(10);
    expect(toUsd(10, "eur")).toBeCloseTo(10 * USD_PER_UNIT.EUR!, 6);
    expect(toUsd(1000, "JPY")).toBeCloseTo(6.7, 6);
    expect(toUsd(10, "XXX")).toBeNull();
    expect(toUsd(10, null)).toBeNull();
  });

  test("Apple price falls back to the plan's US list price for an unknown currency", () => {
    expect(applePriceUsd("pro", 9_990, "EUR")).toEqual({ usd: 10.79, fallback: false, paid: true });
    expect(applePriceUsd("pro", 9_990, "XXX")).toEqual({ usd: 74.99, fallback: true, paid: true });
    expect(applePriceUsd("pro", 0, "USD")).toEqual({ usd: 0, fallback: false, paid: false });
  });
});

describe("net revenue", () => {
  const start = d("2025-01-01T00:00:00Z");
  const record = appleSubscriptionRecord(
    appleRow({ originalTransactionId: "a", status: "active" }),
    monthlyTransactions("a", start, 14),
  );

  test("Apple keeps 30% in the first year of paid service and 15% after", () => {
    expect(appleCommissionRate(record, d("2025-06-15T00:00:00Z"))).toBe(0.3);
    expect(appleCommissionRate(record, d("2025-12-31T00:00:00Z"))).toBe(0.3);
    expect(appleCommissionRate(record, d("2026-01-15T00:00:00Z"))).toBe(0.15);
    expect(mrrAt([record], d("2025-06-15T00:00:00Z"))).toEqual({ grossUsd: 10, netUsd: 7, active: 1 });
    expect(mrrAt([record], d("2026-01-15T00:00:00Z"))).toEqual({ grossUsd: 10, netUsd: 8.5, active: 1 });
  });

  test("a lapse does not count toward the paid-service year", () => {
    const lapsed = appleSubscriptionRecord(appleRow({ originalTransactionId: "b", status: "active" }), [
      ...monthlyTransactions("b", start, 6),
      ...monthlyTransactions("b2", d("2025-12-01T00:00:00Z"), 3).map((tx) => ({ ...tx, originalTransactionId: "b" })),
    ]);
    expect(appleCommissionRate(lapsed, d("2026-02-15T00:00:00Z"))).toBe(0.3);
  });

  test("Stripe net estimate is 2.9% plus 30 cents per charge", () => {
    const record = stripeSubscriptionRecord(stripeRow({ id: "s" }))!;
    expect(stripeNetMonthlyUsd(record.intervals[0]!)).toBe(48.25);
    const yearly = stripeSubscriptionRecord(stripeRow({ id: "y", unitAmount: 120_000, interval: "year" }))!;
    expect(yearly.intervals[0]!.monthlyGrossUsd).toBe(100);
    expect(stripeNetMonthlyUsd(yearly.intervals[0]!)).toBeCloseTo(97.075, 1);
  });

  test("a Stripe price that cannot be read counts at the plan list price, as an estimate", () => {
    const at = d("2026-03-01T00:00:00Z");
    const noPrice = stripeSubscriptionRecord(stripeRow({ id: "n", unitAmount: null }))!;
    const unknownCurrency = stripeSubscriptionRecord(stripeRow({ id: "c", plan: "max", unitAmount: 99_00, currency: "xyz" }))!;
    const team = stripeSubscriptionRecord(stripeRow({ id: "t", plan: "team", unitAmount: null, quantity: 3 }))!;
    expect(mrrAt([noPrice], at).grossUsd).toBe(50);
    expect(mrrAt([unknownCurrency], at).grossUsd).toBe(200);
    expect(mrrAt([team], at).grossUsd).toBe(180);
    expect([noPrice, unknownCurrency, team].map((record) => record.fxFallbacks)).toEqual([1, 1, 1]);
  });

  test("Stripe team MRR multiplies the unit price by seats", () => {
    const team = stripeSubscriptionRecord(stripeRow({ id: "t", plan: "team", unitAmount: 6000, quantity: 3 }))!;
    expect(mrrAt([team], d("2026-03-01T00:00:00Z")).grossUsd).toBe(180);
  });
});

describe("lifecycle", () => {
  test("churn rate is churned over active at the window start", () => {
    expect(churnRate(1, 4)).toBe(0.25);
    expect(churnRate(0, 0)).toBeNull();
  });

  test("grace period keeps a subscription active until the grace end", () => {
    const record = appleSubscriptionRecord(
      appleRow({
        originalTransactionId: "g",
        status: "grace_period",
        gracePeriodExpiresAt: d("2026-02-17T00:00:00Z"),
      }),
      monthlyTransactions("g", d("2026-01-01T00:00:00Z"), 1),
    );
    expect(record.currentStatus).toBe("grace_period");
    expect(isActiveAt(record, d("2026-02-10T00:00:00Z"))).toBe(true);
    expect(isActiveAt(record, d("2026-02-18T00:00:00Z"))).toBe(false);
  });

  test("a refund ends coverage at the revocation and is reported as a refund", () => {
    const row = appleRow({ originalTransactionId: "r", status: "revoked" });
    const transactions = monthlyTransactions("r", d("2026-01-01T00:00:00Z"), 1, {
      revokedAt: d("2026-01-05T00:00:00Z"),
      revocationReason: 0,
    });
    const record = appleSubscriptionRecord(row, transactions);
    expect(isActiveAt(record, d("2026-01-06T00:00:00Z"))).toBe(false);
    expect(appleRefundEvents(row, transactions)).toHaveLength(1);
    const familyRevoke = monthlyTransactions("f", d("2026-01-01T00:00:00Z"), 1, {
      revokedAt: d("2026-01-05T00:00:00Z"),
      revocationReason: null,
    });
    expect(appleRefundEvents(appleRow({ originalTransactionId: "f" }), familyRevoke)).toHaveLength(0);
  });

  test("a free trial is not a paid subscription until it converts", () => {
    const record = appleSubscriptionRecord(appleRow({ originalTransactionId: "t", status: "active" }), [
      ...monthlyTransactions("t", d("2026-01-01T00:00:00Z"), 1, { priceMilliunits: 0 }),
      ...monthlyTransactions("t", d("2026-02-01T00:00:00Z"), 1).map((tx) => ({ ...tx, transactionId: "t-paid" })),
    ]);
    const metrics = computeSubscriptionMetrics([record], [], {
      from: d("2026-01-01T00:00:00Z"),
      to: d("2026-01-20T00:00:00Z"),
      now: d("2026-01-20T00:00:00Z"),
      granularity: "week",
    });
    expect(metrics.kpis.activeSubscriptions).toBe(0);
    expect(metrics.kpis.activeTrials).toBe(1);
    expect(metrics.kpis.newSubscriptions).toBe(0);
  });
});

describe("cohort retention", () => {
  const a = appleSubscriptionRecord(
    appleRow({ originalTransactionId: "a" }),
    monthlyTransactions("a", d("2026-01-10T00:00:00Z"), 3),
  );
  const b = appleSubscriptionRecord(
    appleRow({ originalTransactionId: "b" }),
    monthlyTransactions("b", d("2026-01-20T00:00:00Z"), 1),
  );
  const window = {
    from: d("2026-01-01T00:00:00Z"),
    to: d("2026-06-15T00:00:00Z"),
    now: d("2026-06-15T00:00:00Z"),
  };

  test("tracks each member at their own start plus N months", () => {
    expect(cohortRetention([a, b], window)).toEqual([
      { cohort: "2026-01", size: 2, retention: [1, 0.5, 0.5, 0, 0, 0] },
    ]);
  });

  test("churn and churn rate over a window", () => {
    const metrics = computeSubscriptionMetrics([a, b], [], {
      from: d("2026-03-01T00:00:00Z"),
      to: window.to,
      now: window.now,
      granularity: "month",
    });
    expect(metrics.kpis.activeAtWindowStart).toBe(1);
    expect(metrics.kpis.churned).toBe(1);
    expect(metrics.kpis.churnRate).toBe(1);
    expect(metrics.series.map((point) => point.churned)).toEqual([0, 1, 0, 0]);
  });
});

describe("report", () => {
  const now = d("2026-03-15T00:00:00Z");
  const inputs: AnalyticsInputs = {
    appleSubscriptions: [
      appleRow({ originalTransactionId: "prod", status: "active", storefront: "DEU", currency: "EUR", autoRenewEnabled: false }),
      appleRow({ originalTransactionId: "sbx", status: "active", environment: "Sandbox" }),
    ],
    appleTransactions: [
      ...monthlyTransactions("prod", d("2026-03-01T00:00:00Z"), 1, { currency: "EUR", storefront: "DEU", priceMilliunits: 9_990 }),
      ...monthlyTransactions("sbx", d("2026-03-01T00:00:00Z"), 1),
    ],
    stripeSubscriptions: [
      stripeRow({ id: "live", status: "past_due" }),
      stripeRow({ id: "test", livemode: false }),
      stripeRow({ id: "never", status: "incomplete" }),
    ],
    recentEvents: [],
  };

  test("excludes sandbox by default and labels storefronts", () => {
    const query = parseAnalyticsQuery(new URLSearchParams(), now)!;
    const report = buildAnalyticsReport(inputs, query, now);
    expect(report.filters.environment).toBe("production");
    expect(report.kpis.activeSubscriptions).toBe(2);
    expect(report.kpis.mrrGrossUsd).toBe(60.79);
    expect(report.kpis.billingIssue).toBe(1);
    expect(report.kpis.cancelScheduled).toBe(1);
    expect(report.bySource.apple).toEqual({ active: 1, mrrGrossUsd: 10.79, mrrNetUsd: 7.55 });
    expect(report.storefronts.map((row) => row.country)).toEqual(["STRIPE", "DEU"]);
    expect(report.storefronts.find((row) => row.country === "DEU")?.revenueGrossUsd).toBe(10.79);
  });

  test("source and environment filters", () => {
    const sandbox = parseAnalyticsQuery(new URLSearchParams({ environment: "sandbox", source: "apple" }), now)!;
    expect(buildAnalyticsReport(inputs, sandbox, now).kpis.activeSubscriptions).toBe(1);
    const stripeOnly = parseAnalyticsQuery(new URLSearchParams({ source: "stripe", plan: "go" }), now)!;
    expect(buildAnalyticsReport(inputs, stripeOnly, now).kpis.activeSubscriptions).toBe(0);
  });

  test("query parsing rejects bad values and oversized series", () => {
    expect(parseAnalyticsQuery(new URLSearchParams({ source: "paypal" }), now)).toBeNull();
    expect(parseAnalyticsQuery(new URLSearchParams({ plan: "pro; drop" }), now)).toBeNull();
    expect(parseAnalyticsQuery(new URLSearchParams({ from: "2026-03-10", to: "2026-03-01" }), now)).toBeNull();
    expect(parseAnalyticsQuery(new URLSearchParams({ from: "2024-01-01", granularity: "day" }), now)).toBeNull();
    const ok = parseAnalyticsQuery(new URLSearchParams({ from: "2026-01-01", to: "2026-01-31", granularity: "day" }), now)!;
    expect(ok.to.toISOString()).toBe("2026-01-31T23:59:59.999Z");
    expect(buckets(ok.from, ok.to, "day")).toHaveLength(31);
  });
});
