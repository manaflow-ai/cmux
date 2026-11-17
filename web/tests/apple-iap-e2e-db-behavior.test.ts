// End-to-end billing scenarios for App Store subscriptions. Each test is a
// story told through the real Next route handlers (account-token,
// transactions, notifications, GET /api/billing/plan, and the
// apple-notifications cron) against a real Postgres with every migration
// applied. Only Apple is fake: a local App Store (helpers/apple-fake-app-store)
// whose test signing chain the verifier trusts, serving signed StoreKit
// transactions, App Store Server Notifications, and the App Store Server API
// from one shared state. Stack Auth is an in-memory account directory (the
// `cmuxPlan` mirror lives in its metadata), and the clock is bun's
// setSystemTime, so the scenarios run in milliseconds with no sleeps.
//
// Every step asserts the user's plan twice: the `cmuxPlan` mirror first (what
// Cloud VM limits read, written by the purchase, notification and cron paths),
// then GET /api/billing/plan, which must agree without needing to fix the
// mirror (`metadataChanged: false`).
//
// Gated like the other *-db-behavior tests (CMUX_DB_TEST=1, DATABASE_URL).
// Account deletion (PR #42786) is not on this branch, so it has no scenario.

import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, mock, setSystemTime, test } from "bun:test";
import { NextRequest } from "next/server";
import postgres, { type Sql } from "postgres";

import * as realAnalytics from "../services/analytics/serverEvents";
import * as realErrors from "../services/errors";
import * as realServerApi from "../services/billing/apple/serverApi";
import * as realVerifier from "../services/billing/apple/verifier";
import * as realStack from "../app/lib/stack";
import { FakeAppStore, SUBSCRIPTION_PERIOD_MS, type FakeNotification } from "./helpers/apple-fake-app-store";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
/** Every story starts here; the clock only moves forward inside a story. */
const T0 = Date.UTC(2027, 0, 4, 9, 0, 0);
const CRON_SECRET = "apple-iap-e2e-cron-secret";

// MARK: - The fakes: Apple, Stack accounts, and the analytics/error sinks

let apple = new FakeAppStore();

type Account = {
  readonly id: string;
  readonly email: string;
  metadata: Record<string, unknown>;
  /** Every `clientReadOnlyMetadata` write, in order. */
  readonly writes: Record<string, unknown>[];
};
const accounts = new Map<string, Account>();

function accountUser(account: Account) {
  return {
    id: account.id,
    isAnonymous: false,
    displayName: account.id,
    primaryEmail: account.email,
    primaryEmailVerified: true,
    clientReadOnlyMetadata: structuredClone(account.metadata),
    selectedTeam: null,
    listTeams: async () => [],
    update: async (options: { clientReadOnlyMetadata?: unknown }) => {
      if (options.clientReadOnlyMetadata === undefined) return;
      account.metadata = structuredClone(options.clientReadOnlyMetadata as Record<string, unknown>);
      account.writes.push(structuredClone(account.metadata));
    },
  };
}

const fakeStackApp = {
  getUser: async (options: unknown) => {
    if (typeof options === "string") {
      const account = accounts.get(options);
      return account ? accountUser(account) : null;
    }
    const accessToken = (options as { tokenStore?: { accessToken?: unknown } } | undefined)?.tokenStore?.accessToken;
    if (typeof accessToken === "string" && accessToken.startsWith("access-")) {
      const account = accounts.get(accessToken.slice("access-".length));
      return account ? accountUser(account) : null;
    }
    return null;
  },
};

const events: realAnalytics.ServerEventInput[] = [];
const billingErrors: unknown[] = [];

mock.module("../app/lib/stack", () => ({
  ...realStack,
  isStackConfigured: () => true,
  getStackServerApp: () => fakeStackApp,
}));
// The service caches its dependencies on first use, so these delegate to the
// current story's App Store instead of handing out one instance.
const currentVerifier: realVerifier.AppleSignedDataVerifier = {
  verifyTransaction: (jws) => apple.verifier.verifyTransaction(jws),
  verifyRenewalInfo: (jws, scope) => apple.verifier.verifyRenewalInfo(jws, scope),
  verifyNotification: (payload) => apple.verifier.verifyNotification(payload),
};
const currentServerApi: realServerApi.AppleServerApi = {
  subscriptionStatus: (input) => apple.serverApi.subscriptionStatus(input),
  notificationHistory: (input) => apple.serverApi.notificationHistory(input),
};
mock.module("../services/billing/apple/verifier", () => ({
  ...realVerifier,
  appleSignedDataVerifier: () => currentVerifier,
}));
mock.module("../services/billing/apple/serverApi", () => ({
  ...realServerApi,
  appleServerApi: () => currentServerApi,
}));
mock.module("../services/analytics/serverEvents", () => ({
  ...realAnalytics,
  captureServerEvent: async (input: realAnalytics.ServerEventInput) => {
    events.push(input);
  },
}));
mock.module("../services/errors", () => ({
  ...realErrors,
  captureBillingError: (error: unknown) => {
    billingErrors.push(error);
  },
}));

const { closeCloudDbForTests } = await import("../db/client");
const accountTokenRoute = await import("../app/api/billing/apple/account-token/route");
const transactionsRoute = await import("../app/api/billing/apple/transactions/route");
const notificationsRoute = await import("../app/api/billing/apple/notifications/route");
const planRoute = await import("../app/api/billing/plan/route");
const cronRoute = await import("../app/api/cron/apple-notifications/route");

// MARK: - The clock

const clock = {
  set(ms: number) {
    setSystemTime(new Date(ms));
  },
  now: () => Date.now(),
  advance(ms: number) {
    clock.set(Date.now() + ms);
  },
};

// MARK: - The iOS app, Apple's webhook, the cron, and the plan read

type User = "user-a" | "user-b";

function authHeaders(user: User) {
  return { authorization: `Bearer access-${user}`, "x-stack-refresh-token": `refresh-${user}` };
}

function post(path: string, body: unknown, headers: Record<string, string> = {}) {
  return new Request(`https://cmux.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

const app = {
  /** The app asks for the account's `appAccountToken` before showing products. */
  async accountToken(user: User): Promise<string> {
    const response = await accountTokenRoute.POST(post("/api/billing/apple/account-token", {}, authHeaders(user)));
    expect(response.status).toBe(200);
    const body = await response.json() as { appAccountToken: string };
    return body.appAccountToken;
  },
  async currentPlan(user: User): Promise<{ planId: string; source: string }> {
    const response = await accountTokenRoute.POST(post("/api/billing/apple/account-token", {}, authHeaders(user)));
    return (await response.json() as { currentPlan: { planId: string; source: string } }).currentPlan;
  },
  /** The app posts the StoreKit transaction's `jwsRepresentation`. */
  async postTransaction(user: User, jws: string): Promise<Response> {
    return await transactionsRoute.POST(post("/api/billing/apple/transactions", { signedTransactionInfo: jws }, authHeaders(user)));
  },
};

/** Apple delivers one notification to the webhook. */
async function deliver(notification: FakeNotification): Promise<string> {
  const response = await notificationsRoute.POST(post("/api/billing/apple/notifications", { signedPayload: notification.signedPayload }));
  const body = await response.json() as { outcome?: string; error?: string };
  expect({ status: response.status, body }).toMatchObject({ status: 200, body: { ok: true } });
  return body.outcome!;
}

type CronBody = {
  ok: boolean;
  renewalsChecked: number;
  renewalsExtended: number;
  lapsedUsers: number;
  lapsedDeferred: number;
  lapsesRecovered: number;
  notifications: Record<string, number>;
  history: { failures: number; sources: { bundleId: string; environment: string; notifications: Record<string, number> }[] };
};

/** Vercel Cron calls the Apple billing cron. */
async function runCron(): Promise<CronBody> {
  const response = await cronRoute.GET(new Request("https://cmux.test/api/cron/apple-notifications", {
    headers: { authorization: `Bearer ${CRON_SECRET}` },
  }));
  const body = await response.json() as CronBody;
  expect({ status: response.status, ok: body.ok }).toEqual({ status: 200, ok: true });
  return body;
}

function historyProcessed(body: CronBody): number {
  return body.history.sources.reduce((sum, source) => sum + source.notifications.processed, 0);
}

type Plan = "free" | "go" | "pro" | "max";

/** The `cmuxPlan` mirror alone, without a plan read (which would repair it). */
function expectMirror(user: User, plan: Plan): void {
  const mirror = accounts.get(user)!.metadata.cmuxPlan ?? "free";
  expect({ user, cmuxPlan: mirror }).toEqual({ user, cmuxPlan: plan });
}

/** The mirror, then GET /api/billing/plan, which must agree without changing the mirror. */
async function expectPlan(user: User, plan: Plan): Promise<void> {
  expectMirror(user, plan);
  const response = await planRoute.GET(new NextRequest("https://cmux.test/api/billing/plan", { headers: authHeaders(user) }));
  expect(response.status).toBe(200);
  const body = await response.json() as { subscriptionPlanId: string; billingSource: string; metadataChanged: boolean };
  expect({ user, subscriptionPlanId: body.subscriptionPlanId, billingSource: body.billingSource, metadataChanged: body.metadataChanged })
    .toEqual({ user, subscriptionPlanId: plan, billingSource: plan === "free" ? "none" : "apple", metadataChanged: false });
  expectMirror(user, plan);
}

// MARK: - Database

let sql: Sql | null = null;

type SubscriptionRow = {
  original_transaction_id: string;
  user_id: string;
  plan_id: string;
  product_id: string;
  status: string;
  last_transaction_id: string;
  expires_at: Date | null;
  grace_period_expires_at: Date | null;
  auto_renew_enabled: boolean | null;
  auto_renew_product_id: string | null;
  revoked_at: Date | null;
  updated_at: Date;
  state_signed_at: Date;
};

async function subscriptionRows(): Promise<SubscriptionRow[]> {
  return await sql!<SubscriptionRow[]>`select * from apple_subscriptions order by original_transaction_id`;
}

async function subscriptionRow(originalTransactionId: string): Promise<SubscriptionRow> {
  const [row] = await sql!<SubscriptionRow[]>`
    select * from apple_subscriptions where original_transaction_id = ${originalTransactionId}`;
  if (!row) throw new Error(`no apple_subscriptions row for ${originalTransactionId}`);
  return row;
}

async function transactionRows(): Promise<{ transaction_id: string; user_id: string; revoked_at: Date | null }[]> {
  return await sql!`select transaction_id, user_id, revoked_at from apple_transactions order by transaction_id`;
}

async function ledgerRow(uuid: string) {
  const [row] = await sql!<{ processed_at: Date | null; error: string | null }[]>`
    select processed_at, error from apple_notifications where notification_uuid = ${uuid}`;
  return row ?? null;
}

function grantEventIds(): string[] {
  return [...new Set(events.filter((event) => event.event === "subscription_entitlement_granted").map((event) => event.insertId!))];
}

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2, onnotice: () => undefined });
  process.env.CRON_SECRET = CRON_SECRET;
});

beforeEach(async () => {
  if (!sql) return;
  clock.set(T0);
  apple = new FakeAppStore();
  accounts.clear();
  for (const id of ["user-a", "user-b"] as const) {
    accounts.set(id, { id, email: `${id}@example.test`, metadata: {}, writes: [] });
  }
  events.length = 0;
  billingErrors.length = 0;
  await sql`truncate apple_account_tokens, apple_subscriptions, apple_transactions, apple_notifications,
    apple_notification_history_cursors, account_mutation_leases, stripe_subscriptions, stripe_customers`;
  // Steady state: the history backfill caught up an hour ago on every history it reads.
  for (const bundleId of ["com.cmux.app", "dev.cmux.app.beta"]) {
    for (const environment of ["Production", "Sandbox"]) {
      await sql`insert into apple_notification_history_cursors (bundle_id, environment, next_start_at)
        values (${bundleId}, ${environment}, ${new Date(T0 - HOUR)})`;
    }
  }
});

afterEach(() => {
  if (!sql) return;
  // No scenario expects a billing error report.
  expect(billingErrors).toEqual([]);
});

afterAll(async () => {
  setSystemTime();
  await closeCloudDbForTests();
  await sql?.end();
});

/** user-a buys Pro in the app and the app posts it. Returns the purchase. */
async function buyProAndPost(user: User = "user-a") {
  const token = await app.accountToken(user);
  const purchase = apple.purchase({ token, plan: "pro" });
  clock.advance(MINUTE);
  const response = await app.postTransaction(user, purchase.jws);
  expect(response.status).toBe(200);
  return { token, purchase, expiresAt: T0 + SUBSCRIPTION_PERIOD_MS };
}

// MARK: - Scenarios

describe("Apple in-app purchase scenarios, end to end", () => {
  dbTest("1. buy Pro in the app: Pro at once; the later SUBSCRIBED notification changes nothing", async () => {
    const token = await app.accountToken("user-a");
    await expectPlan("user-a", "free");

    const purchase = apple.purchase({ token, plan: "pro" });
    clock.advance(MINUTE);
    const response = await app.postTransaction("user-a", purchase.jws);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ planId: "pro", status: "active" });
    await expectPlan("user-a", "pro");
    expect(await app.currentPlan("user-a")).toMatchObject({ planId: "pro", source: "apple" });

    const [row] = await subscriptionRows();
    expect(row).toMatchObject({ user_id: "user-a", plan_id: "pro", status: "active", last_transaction_id: purchase.transactionId });
    expect(await transactionRows()).toEqual([{ transaction_id: purchase.transactionId, user_id: "user-a", revoked_at: null }]);

    clock.advance(10 * MINUTE);
    expect(await deliver(purchase.notification)).toBe("processed");
    await expectPlan("user-a", "pro");
    expect(await subscriptionRows()).toEqual([row!]);
    expect(await transactionRows()).toHaveLength(1);
    expect(await deliver(purchase.notification)).toBe("duplicate");

    // One mirror write and one grant (the shared insert id dedupes the second report).
    expect(accounts.get("user-a")!.writes).toEqual([{ cmuxPlan: "pro" }]);
    expect(grantEventIds()).toEqual([`apple_entitlement:${purchase.transactionId}`]);
  });

  dbTest("2. the app never posts: the SUBSCRIBED notification alone grants the token's owner", async () => {
    const token = await app.accountToken("user-a");
    await app.accountToken("user-b");
    const purchase = apple.purchase({ token, plan: "pro" });
    await expectPlan("user-a", "free");

    clock.advance(MINUTE);
    expect(await deliver(purchase.notification)).toBe("processed");
    await expectPlan("user-a", "pro");
    await expectPlan("user-b", "free");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ user_id: "user-a", status: "active" });
  });

  dbTest("3. a renewal with its DID_RENEW delivered extends access past the old expiry", async () => {
    const { purchase, expiresAt } = await buyProAndPost();

    clock.set(expiresAt - HOUR);
    const renewal = apple.renew(purchase.originalTransactionId);
    expect(await deliver(renewal.notification)).toBe("processed");
    const row = await subscriptionRow(purchase.originalTransactionId);
    expect(row).toMatchObject({ status: "active", last_transaction_id: renewal.transactionId });
    expect(row.expires_at?.getTime()).toBe(expiresAt + SUBSCRIPTION_PERIOD_MS);
    await expectPlan("user-a", "pro");

    clock.set(expiresAt + 2 * HOUR);
    expect((await runCron()).lapsedUsers).toBe(0);
    await expectPlan("user-a", "pro");
    expect(await transactionRows()).toHaveLength(2);
  });

  dbTest("4. a lost DID_RENEW with the app never opened: the cron's re-check keeps access, no gap at the old expiry", async () => {
    const { purchase, expiresAt } = await buyProAndPost();

    clock.set(expiresAt - DAY);
    const renewal = apple.renew(purchase.originalTransactionId); // DID_RENEW never arrives
    await expectPlan("user-a", "pro");

    clock.set(expiresAt - 5 * HOUR);
    const cron = await runCron();
    expect({ checked: cron.renewalsChecked, extended: cron.renewalsExtended }).toEqual({ checked: 1, extended: 1 });
    const row = await subscriptionRow(purchase.originalTransactionId);
    expect(row.last_transaction_id).toBe(renewal.transactionId);
    expect(row.expires_at?.getTime()).toBe(expiresAt + SUBSCRIPTION_PERIOD_MS);
    expectMirror("user-a", "pro");

    // The old expiry passes: the plan read (time-checked) still grants Pro.
    clock.set(expiresAt + MINUTE);
    await expectPlan("user-a", "pro");
    clock.set(expiresAt + 2 * HOUR);
    expect((await runCron()).lapsedUsers).toBe(0);
    await expectPlan("user-a", "pro");
    expect(accounts.get("user-a")!.writes).toEqual([{ cmuxPlan: "pro" }]);
  });

  dbTest("5. lost notifications are recovered by the history backfill: a purchase and a refund", async () => {
    const token = await app.accountToken("user-a");
    const purchase = apple.purchase({ token, plan: "pro" }); // the app crashes, the webhook delivery fails
    await expectPlan("user-a", "free");

    clock.advance(30 * MINUTE);
    const first = await runCron();
    expect(historyProcessed(first)).toBe(1);
    expect((await ledgerRow(purchase.notification.uuid))?.processed_at).not.toBeNull();
    await expectPlan("user-a", "pro");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ user_id: "user-a", status: "active" });

    clock.set(T0 + 2 * DAY);
    const refund = apple.refund(purchase.originalTransactionId); // lost too
    await expectPlan("user-a", "pro");
    clock.advance(30 * MINUTE);
    expect(historyProcessed(await runCron())).toBe(1);
    expect((await ledgerRow(refund.uuid))?.processed_at).not.toBeNull();
    await expectPlan("user-a", "free");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ status: "revoked" });
  });

  dbTest("6. a real expiry (auto-renew off, Apple confirms expired) removes the plan only after the leeway", async () => {
    const { purchase, expiresAt } = await buyProAndPost();

    clock.set(T0 + 10 * DAY);
    expect(await deliver(apple.setAutoRenew(purchase.originalTransactionId, false))).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ auto_renew_enabled: false, status: "active" });
    await expectPlan("user-a", "pro");

    clock.set(expiresAt - 5 * HOUR);
    await runCron(); // asks Apple, which still says active: nothing changes
    expectMirror("user-a", "pro");

    clock.set(expiresAt);
    const expired = apple.expire(purchase.originalTransactionId); // EXPIRED is lost
    clock.set(expiresAt + 30 * MINUTE);
    expect((await runCron()).lapsedUsers).toBe(0);
    // Inside the leeway the sweep leaves the mirror (what Cloud VM limits
    // read) alone, since a late renewal may still arrive. A plan read is
    // time-checked and would already show free.
    expectMirror("user-a", "pro");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ status: "active" });

    clock.set(expiresAt + HOUR + MINUTE);
    const callsBefore = apple.statusCalls.length;
    expect((await runCron()).lapsedUsers).toBe(1);
    expect(apple.statusCalls.slice(callsBefore)).toContain(purchase.originalTransactionId);
    await expectPlan("user-a", "free");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ status: "expired" });

    // The EXPIRED notification arriving late changes nothing.
    expect(await deliver(expired)).toBe("processed");
    await expectPlan("user-a", "free");
    expect(accounts.get("user-a")!.writes).toEqual([{ cmuxPlan: "pro" }, {}]);
  });

  dbTest("7. billing retry: access through the grace period, removed at GRACE_PERIOD_EXPIRED, restored on recovery", async () => {
    const { purchase, expiresAt } = await buyProAndPost();

    clock.set(expiresAt);
    expect(await deliver(apple.failRenewal(purchase.originalTransactionId, { graceDays: 16 }))).toBe("processed");
    const grace = await subscriptionRow(purchase.originalTransactionId);
    expect(grace.status).toBe("grace_period");
    expect(grace.grace_period_expires_at?.getTime()).toBe(expiresAt + 16 * DAY);
    await expectPlan("user-a", "pro");

    clock.set(expiresAt + DAY);
    await expectPlan("user-a", "pro");
    clock.set(expiresAt + 16 * DAY - 5 * HOUR);
    await runCron();
    await expectPlan("user-a", "pro");

    clock.set(expiresAt + 16 * DAY);
    expect(await deliver(apple.graceExpired(purchase.originalTransactionId))).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ status: "billing_retry" });
    await expectPlan("user-a", "free");

    clock.set(expiresAt + 20 * DAY);
    const recovery = apple.recoverBilling(purchase.originalTransactionId);
    expect(await deliver(recovery.notification)).toBe("processed");
    const recovered = await subscriptionRow(purchase.originalTransactionId);
    expect(recovered).toMatchObject({ status: "active", last_transaction_id: recovery.transactionId });
    expect(recovered.expires_at?.getTime()).toBe(expiresAt + 20 * DAY + SUBSCRIPTION_PERIOD_MS);
    await expectPlan("user-a", "pro");
  });

  dbTest("8a. a refund of the current period revokes at once; REFUND_REVERSED restores it", async () => {
    const { purchase } = await buyProAndPost();

    clock.set(T0 + 5 * DAY);
    expect(await deliver(apple.refund(purchase.originalTransactionId))).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ status: "revoked" });
    expect((await transactionRows())[0]!.revoked_at).not.toBeNull();
    await expectPlan("user-a", "free");

    clock.set(T0 + 8 * DAY);
    expect(await deliver(apple.reverseRefund(purchase.originalTransactionId, purchase.transactionId))).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ status: "active", revoked_at: null });
    expect((await transactionRows())[0]!.revoked_at).toBeNull();
    await expectPlan("user-a", "pro");
  });

  dbTest("8b. a refund of an older period keeps the current period's access", async () => {
    const { purchase, expiresAt } = await buyProAndPost();
    clock.set(expiresAt - HOUR);
    const renewal = apple.renew(purchase.originalTransactionId);
    expect(await deliver(renewal.notification)).toBe("processed");

    clock.set(expiresAt + 3 * DAY);
    expect(await deliver(apple.refund(purchase.originalTransactionId, purchase.transactionId))).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId))
      .toMatchObject({ status: "active", last_transaction_id: renewal.transactionId, revoked_at: null });
    const refunded = (await transactionRows()).find((row) => row.transaction_id === purchase.transactionId);
    expect(refunded?.revoked_at).not.toBeNull();
    await expectPlan("user-a", "pro");

    // The same, while the App Store Server API is down: the service cannot ask
    // Apple for the current period, so the store's forward-only write alone
    // must keep the refund of a past period from revoking the current one.
    clock.set(expiresAt + 4 * DAY);
    const reversal = apple.reverseRefund(purchase.originalTransactionId, purchase.transactionId);
    clock.advance(MINUTE);
    const refundAgain = apple.refund(purchase.originalTransactionId, purchase.transactionId);
    apple.serverApiOutage = true;
    expect(await deliver(reversal)).toBe("processed");
    expect(await deliver(refundAgain)).toBe("processed");
    apple.serverApiOutage = false;
    expect(await subscriptionRow(purchase.originalTransactionId))
      .toMatchObject({ status: "active", last_transaction_id: renewal.transactionId, revoked_at: null });
    await expectPlan("user-a", "pro");
  });

  dbTest("9. an upgrade to Max applies at once; a downgrade to Pro waits for the renewal", async () => {
    const { purchase } = await buyProAndPost();

    clock.set(T0 + 3 * DAY);
    const upgrade = apple.upgrade(purchase.originalTransactionId, "max");
    const response = await app.postTransaction("user-a", upgrade.jws);
    expect(await response.json()).toMatchObject({ planId: "max", status: "active" });
    await expectPlan("user-a", "max");
    clock.advance(MINUTE);
    expect(await deliver(upgrade.notification)).toBe("processed");
    await expectPlan("user-a", "max");

    clock.set(T0 + 10 * DAY);
    expect(await deliver(apple.downgrade(purchase.originalTransactionId, "pro"))).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId))
      .toMatchObject({ plan_id: "max", auto_renew_product_id: "com.cmux.app.pro.monthly" });
    await expectPlan("user-a", "max");

    const maxEnds = T0 + 3 * DAY + SUBSCRIPTION_PERIOD_MS;
    clock.set(maxEnds - 2 * HOUR);
    await expectPlan("user-a", "max");
    clock.set(maxEnds - HOUR);
    const renewal = apple.renew(purchase.originalTransactionId);
    expect(await deliver(renewal.notification)).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ plan_id: "pro", product_id: "com.cmux.app.pro.monthly" });
    await expectPlan("user-a", "pro");
    clock.set(maxEnds + DAY);
    await expectPlan("user-a", "pro");
    expect(accounts.get("user-a")!.writes).toEqual([{ cmuxPlan: "pro" }, { cmuxPlan: "max" }, { cmuxPlan: "pro" }]);
  });

  dbTest("10a. account B posting account A's transaction before A's app does gets 403; A's app then gets Pro", async () => {
    const tokenA = await app.accountToken("user-a");
    await app.accountToken("user-b");
    const purchase = apple.purchase({ token: tokenA, plan: "pro" });

    clock.advance(MINUTE);
    const stolen = await app.postTransaction("user-b", purchase.jws);
    expect(stolen.status).toBe(403);
    expect(await stolen.json()).toEqual({ error: "account_mismatch" });
    expect(await subscriptionRows()).toEqual([]);
    expect(await transactionRows()).toEqual([]);
    await expectPlan("user-b", "free");
    await expectPlan("user-a", "free");

    expect((await app.postTransaction("user-a", purchase.jws)).status).toBe(200);
    await expectPlan("user-a", "pro");
    await expectPlan("user-b", "free");
  });

  dbTest("10b. account B posting account A's transaction gets 403 account_mismatch; A keeps the plan", async () => {
    const { purchase } = await buyProAndPost("user-a");
    await app.accountToken("user-b");
    const before = await subscriptionRows();

    clock.advance(MINUTE);
    const response = await app.postTransaction("user-b", purchase.jws);
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "account_mismatch" });

    await expectPlan("user-a", "pro");
    await expectPlan("user-b", "free");
    expect(await subscriptionRows()).toEqual(before);
    expect((await transactionRows()).map((row) => row.user_id)).toEqual(["user-a"]);
  });

  dbTest("11. the same Apple ID buys again from account B: the subscription moves to B and A falls back", async () => {
    const { purchase } = await buyProAndPost("user-a");

    clock.set(T0 + 4 * DAY);
    const tokenB = await app.accountToken("user-b");
    const upgrade = apple.upgrade(purchase.originalTransactionId, "max", { token: tokenB });
    const response = await app.postTransaction("user-b", upgrade.jws);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ planId: "max" });

    await expectPlan("user-b", "max");
    await expectPlan("user-a", "free");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ user_id: "user-b", plan_id: "max" });

    clock.advance(MINUTE);
    expect(await deliver(upgrade.notification)).toBe("processed");
    await expectPlan("user-b", "max");
    await expectPlan("user-a", "free");

    // A's old transaction, posted again by A's app, cannot pull it back.
    const stale = await app.postTransaction("user-a", apple.appTransaction(purchase.originalTransactionId, purchase.transactionId));
    expect(stale.status).toBe(403);
    await expectPlan("user-a", "free");
    await expectPlan("user-b", "max");
  });

  dbTest("12. a Family Sharing copy never grants, and revoking it never touches the purchaser", async () => {
    const { purchase } = await buyProAndPost("user-a");
    await app.accountToken("user-b");

    clock.set(T0 + DAY);
    const copy = apple.familyCopy(purchase.originalTransactionId);
    expect(await deliver(copy.notification)).toBe("skipped");
    const response = await app.postTransaction("user-b", copy.jws);
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "family_shared" });
    await expectPlan("user-b", "free");
    await expectPlan("user-a", "pro");
    expect((await subscriptionRows()).map((row) => row.original_transaction_id)).toEqual([purchase.originalTransactionId]);

    clock.set(T0 + 2 * DAY);
    expect(await deliver(apple.revokeFamilyAccess(copy.originalTransactionId))).toBe("skipped");
    expect(await deliver(apple.familyRevokeNamingPurchaser(purchase.originalTransactionId))).toBe("skipped");
    await expectPlan("user-a", "pro");
    await expectPlan("user-b", "free");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ user_id: "user-a", status: "active" });
  });

  dbTest("13. duplicate and out-of-order notifications settle on the right state with one grant", async () => {
    const token = await app.accountToken("user-a");
    const purchase = apple.purchase({ token, plan: "pro" });
    const expiresAt = T0 + SUBSCRIPTION_PERIOD_MS;
    clock.set(expiresAt - HOUR);
    const renewal = apple.renew(purchase.originalTransactionId);
    clock.set(expiresAt + 2 * DAY);
    const upgrade = apple.upgrade(purchase.originalTransactionId, "max");

    // Apple's queue was stuck; everything arrives at once, newest first, twice.
    clock.advance(5 * MINUTE);
    const order = [upgrade.notification, purchase.notification, renewal.notification, upgrade.notification, purchase.notification, renewal.notification];
    const outcomes: string[] = [];
    for (const notification of order) {
      outcomes.push(await deliver(notification));
      await expectPlan("user-a", "max");
    }
    expect(outcomes).toEqual(["processed", "processed", "processed", "duplicate", "duplicate", "duplicate"]);
    expect(await subscriptionRows()).toHaveLength(1);
    expect(await subscriptionRow(purchase.originalTransactionId))
      .toMatchObject({ plan_id: "max", status: "active", last_transaction_id: upgrade.transactionId });
    expect((await transactionRows()).map((row) => row.transaction_id).sort())
      .toEqual([purchase.transactionId, renewal.transactionId, upgrade.transactionId].sort());
    expect(accounts.get("user-a")!.writes).toEqual([{ cmuxPlan: "max" }]);
    expect(grantEventIds()).toEqual([`apple_entitlement:${upgrade.transactionId}`]);
  });

  dbTest("14. an Apple outage during the app's post answers 503; the retry after it succeeds", async () => {
    const token = await app.accountToken("user-a");
    const purchase = apple.purchase({ token, plan: "pro" });

    apple.verificationOutage = true;
    clock.advance(MINUTE);
    const failed = await app.postTransaction("user-a", purchase.jws);
    expect(failed.status).toBe(503);
    expect(failed.headers.get("retry-after")).toBe("30");
    expect(await failed.json()).toEqual({ error: "verification_unavailable" });
    // Apple's webhook delivery fails the same way, so Apple retries it.
    const webhook = await notificationsRoute.POST(post("/api/billing/apple/notifications", { signedPayload: purchase.notification.signedPayload }));
    expect(webhook.status).toBe(503);
    expect(await subscriptionRows()).toEqual([]);
    await expectPlan("user-a", "free");
    billingErrors.length = 0; // the webhook 503 is reported, as it should be

    apple.verificationOutage = false;
    clock.advance(2 * MINUTE);
    const retried = await app.postTransaction("user-a", purchase.jws);
    expect(retried.status).toBe(200);
    await expectPlan("user-a", "pro");
    clock.advance(5 * MINUTE);
    expect(await deliver(purchase.notification)).toBe("processed");
    await expectPlan("user-a", "pro");
    expect(accounts.get("user-a")!.writes).toEqual([{ cmuxPlan: "pro" }]);
  });
});
