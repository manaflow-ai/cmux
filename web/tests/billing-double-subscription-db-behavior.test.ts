// Database-backed proof of the double billing store: which Stripe rows count,
// the scan's candidate join, incident upsert and reopen, and resolution.
// Gated like the other *-db-behavior tests.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { databaseDoubleBillingStore, type DoubleBillingIncidentWrite } from "../services/billing/doubleBilling";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const store = databaseDoubleBillingStore();
const NOW = new Date();
const DAY = 24 * 60 * 60 * 1000;

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate billing_double_subscription_incidents, apple_subscriptions, stripe_subscriptions`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

async function stripeRow(id: string, values: { user: string; plan?: string; status?: string; scope?: string; team?: string | null; raw?: unknown }) {
  await sql!`insert into stripe_subscriptions (id, customer_id, stack_user_id, stack_team_id, status, plan, scope, raw)
    values (${id}, 'cus_1', ${values.user}, ${values.team ?? null}, ${values.status ?? "active"}, ${values.plan ?? "pro"},
      ${values.scope ?? "user"}, ${values.raw ? sql!.json(values.raw as never) : null})`;
}

async function appleRow(id: string, values: { user: string; status?: string; environment?: string }) {
  await sql!`insert into apple_subscriptions (original_transaction_id, user_id, bundle_id, environment, product_id, plan_id, status,
      auto_renew_enabled, expires_at, state_signed_at)
    values (${id}, ${values.user}, 'com.cmux.app', ${values.environment ?? "Production"}, 'com.cmux.app.pro.monthly', 'pro',
      ${values.status ?? "active"}, true, ${new Date(NOW.getTime() + 20 * DAY)}, ${NOW})`;
}

function incident(overrides: Partial<DoubleBillingIncidentWrite> = {}): DoubleBillingIncidentWrite {
  return {
    userId: "user-a",
    stripeSubscriptionId: "sub_a",
    stripePlanId: "pro",
    stripeStatus: "active",
    appleOriginalTransactionId: "otx-a",
    applePlanId: "pro",
    appleStatus: "active",
    appleEnvironment: "Production",
    appleAutoRenewEnabled: true,
    detectedBy: "stripe_checkout",
    detectedAt: NOW,
    ...overrides,
  };
}

describe("double billing store", () => {
  dbTest("reads only active, recurring, personal Stripe subscriptions", async () => {
    await stripeRow("sub_active", { user: "user-a" });
    await stripeRow("sub_past_due", { user: "user-a", plan: "max", status: "past_due" });
    await stripeRow("sub_canceled", { user: "user-a", status: "canceled" });
    await stripeRow("sub_team", { user: "user-a", plan: "team", scope: "team", team: "team-1" });
    await stripeRow("founders_cs_1", { user: "user-a" });
    await stripeRow("sub_founder_meta", { user: "user-a", raw: { metadata: { founders_edition: "true" } } });
    await stripeRow("sub_other", { user: "user-b" });
    const rows = await store.stripeSubscriptions("user-a");
    expect(rows.map((row) => row.id).sort()).toEqual(["sub_active", "sub_past_due"]);
  });

  dbTest("the scan's candidates have a Production App Store row and an active personal Stripe row", async () => {
    await stripeRow("sub_a", { user: "user-a" });
    await appleRow("otx-a", { user: "user-a", status: "billing_retry" });
    await stripeRow("sub_b", { user: "user-b" });
    await appleRow("otx-b", { user: "user-b", environment: "Sandbox" });
    await stripeRow("sub_c", { user: "user-c", status: "canceled" });
    await appleRow("otx-c", { user: "user-c" });
    await stripeRow("sub_d", { user: "user-d" });
    await appleRow("otx-d", { user: "user-d", status: "expired" });
    expect(await store.usersWithBothSources()).toEqual(["user-a"]);
  });

  dbTest("an incident opens once, updates on repeat, and reopens after resolution", async () => {
    const first = await store.recordIncident(incident());
    expect(first.opened).toBe(true);
    const repeat = await store.recordIncident(incident({ detectedBy: "daily_scan", appleStatus: "billing_retry" }));
    expect(repeat).toEqual({ id: first.id, opened: false });

    // An incident seen at the scan's start time is not resolved by that scan.
    expect(await store.resolveIncidentsExcept({ keepIds: [], keepUserIds: [], now: NOW })).toBe(0);
    expect(await store.resolveIncidentsExcept({ keepIds: [], keepUserIds: [], now: new Date(NOW.getTime() + 1000) })).toBe(1);
    expect((await store.listIncidents({ includeResolved: false, limit: 10 }))).toEqual([]);
    const [resolved] = await store.listIncidents({ includeResolved: true, limit: 10 });
    expect(resolved).toMatchObject({ id: first.id, firstDetectedBy: "stripe_checkout", detectedBy: "daily_scan", appleStatus: "billing_retry" });
    expect(resolved!.resolvedAt).not.toBeNull();

    expect(await store.recordIncident(incident())).toEqual({ id: first.id, opened: true });
  });

  dbTest("resolution keeps listed incidents and listed users' incidents", async () => {
    const keep = await store.recordIncident(incident());
    await store.recordIncident(incident({ userId: "user-b", stripeSubscriptionId: "sub_b" }));
    await store.recordIncident(incident({ userId: "user-c", stripeSubscriptionId: "sub_c" }));
    expect(await store.resolveIncidentsExcept({ keepIds: [keep.id], keepUserIds: ["user-b"], now: new Date(NOW.getTime() + 1000) })).toBe(1);
    const open = await store.listIncidents({ includeResolved: false, limit: 10 });
    expect(open.map((row) => row.userId).sort()).toEqual(["user-a", "user-b"]);
  });

  dbTest("concurrent detections of one pair make one incident", async () => {
    const results = await Promise.all([store.recordIncident(incident()), store.recordIncident(incident())]);
    expect(results.filter((result) => result.opened)).toHaveLength(1);
    expect(new Set(results.map((result) => result.id)).size).toBe(1);
  });
});
