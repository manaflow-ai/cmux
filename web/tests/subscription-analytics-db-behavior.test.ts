// Database-backed proof of the subscription analytics query layer: the JSON
// projections of the raw Stripe payload and the Apple ledgers, the
// environment filters, and the notification join. Gated like the other
// *-db-behavior tests.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { buildAnalyticsReport, loadAnalyticsInputs, parseAnalyticsQuery } from "../services/billing/analytics/query";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const NOW = new Date("2026-03-15T00:00:00.000Z");

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate apple_subscriptions, apple_transactions, apple_notifications, stripe_subscriptions`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

async function seed(db: Sql) {
  for (const [id, environment, storefront, currency, price] of [
    ["otx-prod", "Production", "DEU", "EUR", 9990],
    ["otx-sbx", "Sandbox", "USA", "USD", 74990],
  ] as const) {
    await db`insert into apple_subscriptions (
      original_transaction_id, user_id, bundle_id, environment, product_id, plan_id, status,
      auto_renew_enabled, purchase_date, original_purchase_date, expires_at, storefront, currency,
      price_milliunits, state_signed_at
    ) values (
      ${id}, ${`user-${id}`}, 'com.cmux.app', ${environment}, 'com.cmux.app.pro.monthly', 'pro', 'active',
      false, '2026-03-01T00:00:00Z', '2026-03-01T00:00:00Z', '2026-04-01T00:00:00Z', ${storefront}, ${currency},
      ${price}, '2026-03-01T00:00:00Z'
    )`;
    await db`insert into apple_transactions (
      transaction_id, original_transaction_id, user_id, product_id, plan_id, environment, purchase_date,
      expires_at, price_milliunits, currency, storefront, payload
    ) values (
      ${`${id}-1`}, ${id}, ${`user-${id}`}, 'com.cmux.app.pro.monthly', 'pro', ${environment},
      '2026-03-01T00:00:00Z', '2026-04-01T00:00:00Z', ${price}, ${currency}, ${storefront}, ${db.json({})}
    )`;
  }
  await db`insert into apple_transactions (
    transaction_id, original_transaction_id, user_id, product_id, plan_id, environment, purchase_date,
    expires_at, price_milliunits, currency, storefront, revoked_at, payload
  ) values (
    'otx-prod-refunded', 'otx-prod', 'user-otx-prod', 'com.cmux.app.pro.monthly', 'pro', 'Production',
    '2026-02-01T00:00:00Z', '2026-03-01T00:00:00Z', 9990, 'EUR', 'DEU', '2026-02-03T00:00:00Z',
    ${db.json({ revocationReason: 0 })}
  )`;
  await db`insert into apple_notifications (
    notification_uuid, notification_type, subtype, environment, original_transaction_id, signed_date, payload,
    processed_at
  ) values (
    'n-1', 'SUBSCRIBED', 'INITIAL_BUY', 'Production', 'otx-prod', '2026-03-01T00:00:00Z',
    ${db.json({ data: { transactionInfo: { productId: "com.cmux.app.pro.monthly", price: 9990, currency: "EUR", storefront: "DEU" } } })},
    '2026-03-01T00:00:01Z'
  )`;
  for (const [id, livemode, quantity] of [["sub_live", true, 3], ["sub_test", false, 1]] as const) {
    await db`insert into stripe_subscriptions (id, customer_id, stack_user_id, status, plan, scope, raw)
      values (${id}, 'cus_1', ${`user-${id}`}, 'active', 'team', 'team', ${db.json({
        livemode,
        start_date: Date.parse("2026-01-01T00:00:00Z") / 1000,
        items: { data: [{ quantity, price: { unit_amount: 6000, currency: "usd", recurring: { interval: "month", interval_count: 1 } } }] },
      })})`;
  }
}

describe("subscription analytics query layer", () => {
  dbTest("projects Stripe and Apple rows and excludes sandbox by default", async () => {
    await seed(sql!);
    const query = parseAnalyticsQuery(new URLSearchParams({ from: "2026-01-01" }), NOW)!;
    const inputs = await loadAnalyticsInputs(query);
    expect(inputs.appleSubscriptions.map((row) => row.originalTransactionId)).toEqual(["otx-prod"]);
    expect(inputs.stripeSubscriptions).toHaveLength(1);
    expect(inputs.stripeSubscriptions[0]).toMatchObject({ livemode: true, unitAmount: 6000, quantity: 3, interval: "month" });
    expect(inputs.appleTransactions.find((tx) => tx.transactionId === "otx-prod-refunded")?.revocationReason).toBe(0);

    const report = buildAnalyticsReport(inputs, query, NOW);
    expect(report.kpis.activeSubscriptions).toBe(2);
    expect(report.kpis.mrrGrossUsd).toBe(190.79);
    expect(report.kpis.refunds).toEqual({ count: 1, amountUsd: 10.79 });
    expect(report.kpis.cancelScheduled).toBe(1);
    expect(report.recentEvents).toEqual([
      expect.objectContaining({ type: "SUBSCRIBED", userId: "user-otx-prod", planId: "pro", price: 9.99, currency: "EUR" }),
    ]);

    const sandbox = parseAnalyticsQuery(new URLSearchParams({ from: "2026-01-01", environment: "sandbox" }), NOW)!;
    const sandboxInputs = await loadAnalyticsInputs(sandbox);
    expect(sandboxInputs.appleSubscriptions.map((row) => row.originalTransactionId)).toEqual(["otx-sbx"]);
    expect(sandboxInputs.stripeSubscriptions.map((row) => row.id)).toEqual(["sub_test"]);
  });
});
