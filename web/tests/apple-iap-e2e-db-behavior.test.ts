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
// Between the cron runs a story makes, the real cron runs every 30 minutes
// and its history backfill keeps up. runCron models that by moving the
// backfill cursors up to an hour before now, after checking that every
// notification Apple's history holds in the skipped span is already in the
// ledger, so the shortcut never hides a notification the backfill would
// have applied.
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
const dbTest = test.if(runDbTests);

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
/** Every story starts here; the clock only moves forward inside a story. */
const T0 = Date.UTC(2027, 0, 4, 9, 0, 0);
/** When the first subscription bought at T0 ends. */
const E = T0 + SUBSCRIPTION_PERIOD_MS;
const CRON_SECRET = "apple-iap-e2e-cron-secret";

/** Deployment settings that change which histories are read and which Sandbox rows grant; unset for every story. */
const PINNED_ENV = [
  "VERCEL_ENV",
  "APPLE_IAP_BUNDLE_IDS",
  "APPLE_IAP_APP_APPLE_ID",
  "APPLE_IAP_SANDBOX_ENTITLEMENTS",
  "APPLE_IAP_SANDBOX_ACCOUNT_EMAILS",
  "APPLE_IAP_ONLINE_CHECKS",
  "CMUX_LOCAL_DEV_PRO",
] as const;
const savedEnv = new Map<string, string | undefined>();

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
/** Server-side user lookups (the plan re-derive) that fail before succeeding again. */
let stackLookupFailures = 0;

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
      if (stackLookupFailures > 0) {
        stackLookupFailures -= 1;
        throw new Error("Stack Auth unavailable (fake outage)");
      }
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

mock.module("../app/lib/stack", () => ({
  ...realStack,
  isStackConfigured: () => true,
  getStackServerApp: () => fakeStackApp,
}));
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
  renewalCheckFailures: number;
  lapsedUsers: number;
  lapsedDeferred: number;
  lapsesRecovered: number;
  notifications: Record<string, number>;
  history: { failures: number; sources: { bundleId: string; environment: string; notifications: Record<string, number> }[] };
};

/**
 * Stands in for the crons between the last run and now: their backfill
 * would have read Apple's history up to about an hour ago. Every
 * notification in that span must already be in the ledger (delivered, or
 * read by an earlier runCron); otherwise the story skipped a cron it needs.
 */
async function keepBackfillCaughtUp(): Promise<void> {
  const caughtUpTo = clock.now() - HOUR;
  const cursors = await sql!<{ bundle_id: string; environment: string; next_start_at: Date }[]>`
    select bundle_id, environment, next_start_at from apple_notification_history_cursors where pagination_token is null`;
  for (const cursor of cursors) {
    if (cursor.next_start_at.getTime() >= caughtUpTo) continue;
    const from = cursor.next_start_at.getTime() - HOUR;
    for (const notification of apple.history) {
      if (notification.bundleId !== cursor.bundle_id || notification.environment !== cursor.environment) continue;
      if (!apple.isInHistory(notification) || notification.signedDate < from || notification.signedDate > caughtUpTo) continue;
      expect({ skippedByBackfillShortcut: notification.type, inLedger: (await ledgerRow(notification.uuid)) !== null })
        .toEqual({ skippedByBackfillShortcut: notification.type, inLedger: true });
    }
    await sql!`update apple_notification_history_cursors set next_start_at = ${new Date(caughtUpTo)}
      where bundle_id = ${cursor.bundle_id} and environment = ${cursor.environment}`;
  }
}

/** Vercel Cron calls the Apple billing cron. */
async function runCron(options: { readonly expectOk?: boolean } = {}): Promise<CronBody> {
  await keepBackfillCaughtUp();
  const response = await cronRoute.GET(new Request("https://cmux.test/api/cron/apple-notifications", {
    headers: { authorization: `Bearer ${CRON_SECRET}` },
  }));
  const body = await response.json() as CronBody;
  const ok = options.expectOk ?? true;
  expect({ status: response.status, ok: body.ok }).toEqual({ status: ok ? 200 : 503, ok });
  return body;
}

function historyProcessed(body: CronBody): number {
  return body.history.sources.reduce((sum, source) => sum + source.notifications.processed, 0);
}

type Plan = "free" | "go" | "pro" | "max";
type Source = "apple" | "stripe" | "none";

/** The `cmuxPlan` mirror alone, without a plan read (which would repair it). */
function expectMirror(user: User, plan: Plan): void {
  const mirror = accounts.get(user)!.metadata.cmuxPlan ?? "free";
  expect({ user, at: new Date(clock.now()).toISOString(), cmuxPlan: mirror })
    .toEqual({ user, at: new Date(clock.now()).toISOString(), cmuxPlan: plan });
}

async function readPlan(user: User) {
  const response = await planRoute.GET(new NextRequest("https://cmux.test/api/billing/plan", { headers: authHeaders(user) }));
  expect(response.status).toBe(200);
  return await response.json() as { subscriptionPlanId: string; billingSource: string; metadataChanged: boolean };
}

/** The mirror, then GET /api/billing/plan, which must agree without changing the mirror. */
async function expectPlan(user: User, plan: Plan, source: Source = plan === "free" ? "none" : "apple"): Promise<void> {
  expectMirror(user, plan);
  const body = await readPlan(user);
  const at = new Date(clock.now()).toISOString();
  expect({ user, at, subscriptionPlanId: body.subscriptionPlanId, billingSource: body.billingSource, metadataChanged: body.metadataChanged })
    .toEqual({ user, at, subscriptionPlanId: plan, billingSource: source, metadataChanged: false });
  expectMirror(user, plan);
}

/** Runs the cron every 30 minutes from `from` to `to`, checking the plan before each run. */
async function cronEveryHalfHour(from: number, to: number, user: User, plan: Plan): Promise<CronBody[]> {
  const runs: CronBody[] = [];
  for (let at = from; at <= to; at += 30 * MINUTE) {
    clock.set(at);
    await expectPlan(user, plan);
    runs.push(await runCron());
  }
  return runs;
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
  const [row] = await sql!<{ processed_at: Date | null; error: string | null; attempt_count: number; next_attempt_at: Date | null }[]>`
    select processed_at, error, attempt_count, next_attempt_at from apple_notifications where notification_uuid = ${uuid}`;
  return row ?? null;
}

/**
 * The insert ids of every `subscription_entitlement_granted` event. The
 * app post and the notification for one transaction may both report the
 * grant; analytics dedupes on this id, so one id is one grant.
 */
function grantInsertIds(): string[] {
  return [...new Set(events.filter((event) => event.event === "subscription_entitlement_granted").map((event) => event.insertId!))];
}

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2, onnotice: () => undefined });
  for (const name of [...PINNED_ENV, "CRON_SECRET"]) savedEnv.set(name, process.env[name]);
  for (const name of PINNED_ENV) delete process.env[name];
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
  stackLookupFailures = 0;
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
  // A story that expects an error report checks and clears it itself.
  expect(billingErrors).toEqual([]);
});

afterAll(async () => {
  setSystemTime();
  for (const [name, value] of savedEnv) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
  await closeCloudDbForTests();
  await sql?.end();
});

/** The user buys Pro in the app at T0, the app posts it, and Apple's SUBSCRIBED arrives. */
async function buyProAndPost(user: User = "user-a") {
  const token = await app.accountToken(user);
  const purchase = apple.purchase({ token, plan: "pro" });
  clock.advance(MINUTE);
  const response = await app.postTransaction(user, purchase.jws);
  expect(response.status).toBe(200);
  clock.advance(MINUTE);
  expect(await deliver(purchase.notification)).toBe("processed");
  return { token, purchase };
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

    // One mirror write and one grant id (the post and the notification share it).
    expect(accounts.get("user-a")!.writes).toEqual([{ cmuxPlan: "pro" }]);
    expect(grantInsertIds()).toEqual([`apple_entitlement:${purchase.transactionId}`]);
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
    const { purchase } = await buyProAndPost();

    clock.set(E - HOUR);
    const renewal = apple.renew(purchase.originalTransactionId);
    expect(await deliver(renewal.notification)).toBe("processed");
    const row = await subscriptionRow(purchase.originalTransactionId);
    expect(row).toMatchObject({ status: "active", last_transaction_id: renewal.transactionId });
    expect(row.expires_at?.getTime()).toBe(E + SUBSCRIPTION_PERIOD_MS);
    await expectPlan("user-a", "pro");

    await cronEveryHalfHour(E - 30 * MINUTE, E + 2 * HOUR, "user-a", "pro");
    await expectPlan("user-a", "pro");
    expect(await transactionRows()).toHaveLength(2);
  });

  dbTest("4. a lost DID_RENEW with the app never opened: the cron's re-check keeps access, no gap at the old expiry", async () => {
    const { purchase } = await buyProAndPost();

    clock.set(E - DAY);
    const renewal = apple.renew(purchase.originalTransactionId);
    // Never delivered, and missing from Apple's history too, so only the re-check can find it.
    apple.omitFromHistory(renewal.notification);
    await expectPlan("user-a", "pro");

    // The cron every half hour from six hours before the old expiry to two hours after:
    // the plan holds at every run, and the first run in the window already extends it.
    const runs = await cronEveryHalfHour(E - 6 * HOUR, E + 2 * HOUR, "user-a", "pro");
    expect(runs[0]).toMatchObject({ renewalsChecked: 1, renewalsExtended: 1 });
    expect(runs.reduce((sum, run) => sum + run.renewalsExtended + run.lapsedUsers, 0)).toBe(1);
    const row = await subscriptionRow(purchase.originalTransactionId);
    expect(row.last_transaction_id).toBe(renewal.transactionId);
    expect(row.expires_at?.getTime()).toBe(E + SUBSCRIPTION_PERIOD_MS);
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

  dbTest("6a. a real expiry with EXPIRED lost everywhere: the sweep removes the plan only after the leeway, once Apple confirms", async () => {
    const { purchase } = await buyProAndPost();

    clock.set(T0 + 10 * DAY);
    expect(await deliver(apple.setAutoRenew(purchase.originalTransactionId, false))).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ auto_renew_enabled: false, status: "active" });
    await expectPlan("user-a", "pro");

    // The re-check still asks Apple before expiry (auto-renew may come back on); Apple says active.
    clock.set(E - 5 * HOUR);
    expect((await runCron()).renewalsChecked).toBe(1);
    expectMirror("user-a", "pro");

    clock.set(E);
    const expired = apple.expire(purchase.originalTransactionId);
    apple.omitFromHistory(expired);
    clock.set(E + 30 * MINUTE);
    expect((await runCron()).lapsedUsers).toBe(0);
    // Inside the leeway the sweep leaves the mirror (what Cloud VM limits read) alone.
    expectMirror("user-a", "pro");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ status: "active" });

    clock.set(E + HOUR + MINUTE);
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

  dbTest("6b. a real expiry whose EXPIRED delivery failed: the backfill applies it at the first cron after expiry", async () => {
    const { purchase } = await buyProAndPost();
    clock.set(T0 + 10 * DAY);
    expect(await deliver(apple.setAutoRenew(purchase.originalTransactionId, false))).toBe("processed");

    clock.set(E);
    apple.expire(purchase.originalTransactionId); // the webhook delivery fails; Apple's history has it
    clock.set(E + 30 * MINUTE);
    const cron = await runCron();
    expect({ historyProcessed: historyProcessed(cron), lapsedUsers: cron.lapsedUsers }).toEqual({ historyProcessed: 1, lapsedUsers: 0 });
    await expectPlan("user-a", "free");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ status: "expired" });
  });

  dbTest("6c. a plan read is time-checked: right after expiry it shows free and drops the mirror, leeway or not", async () => {
    const { purchase } = await buyProAndPost();
    clock.set(T0 + 10 * DAY);
    expect(await deliver(apple.setAutoRenew(purchase.originalTransactionId, false))).toBe("processed");

    clock.set(E + 5 * MINUTE);
    apple.omitFromHistory(apple.expire(purchase.originalTransactionId));
    expectMirror("user-a", "pro");
    const read = await readPlan("user-a");
    expect({ plan: read.subscriptionPlanId, metadataChanged: read.metadataChanged }).toEqual({ plan: "free", metadataChanged: true });
    expectMirror("user-a", "free");
    // The sweep later finds nothing left to remove.
    clock.set(E + 2 * HOUR);
    await runCron();
    await expectPlan("user-a", "free");
  });

  dbTest("7a. billing retry: access through the grace period, removed at GRACE_PERIOD_EXPIRED, restored when a lost recovery is backfilled", async () => {
    const { purchase } = await buyProAndPost();

    clock.set(E);
    expect(await deliver(apple.failRenewal(purchase.originalTransactionId, { graceDays: 16 }))).toBe("processed");
    const grace = await subscriptionRow(purchase.originalTransactionId);
    expect(grace.status).toBe("grace_period");
    expect(grace.grace_period_expires_at?.getTime()).toBe(E + 16 * DAY);
    await expectPlan("user-a", "pro");

    clock.set(E + DAY);
    await expectPlan("user-a", "pro");
    clock.set(E + 16 * DAY - 5 * HOUR);
    await runCron();
    await expectPlan("user-a", "pro");

    clock.set(E + 16 * DAY);
    expect(await deliver(apple.graceExpired(purchase.originalTransactionId))).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ status: "billing_retry" });
    await expectPlan("user-a", "free");

    clock.set(E + 20 * DAY);
    const recovery = apple.recoverBilling(purchase.originalTransactionId); // BILLING_RECOVERY delivery fails
    await expectPlan("user-a", "free");
    clock.advance(30 * MINUTE);
    expect(historyProcessed(await runCron())).toBe(1);
    const recovered = await subscriptionRow(purchase.originalTransactionId);
    expect(recovered).toMatchObject({ status: "active", last_transaction_id: recovery.transactionId });
    expect(recovered.expires_at?.getTime()).toBe(E + 20 * DAY + SUBSCRIPTION_PERIOD_MS);
    await expectPlan("user-a", "pro");
  });

  dbTest("7b. a failed renewal with no grace period removes access at once", async () => {
    const { purchase } = await buyProAndPost();
    clock.set(E);
    expect(await deliver(apple.failRenewal(purchase.originalTransactionId, { graceDays: 0 }))).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ status: "billing_retry", grace_period_expires_at: null });
    await expectPlan("user-a", "free");
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

  dbTest("8b. a refund of an older period keeps the current period's access, also while the Server API is down", async () => {
    const { purchase } = await buyProAndPost();
    clock.set(E - HOUR);
    const renewal = apple.renew(purchase.originalTransactionId);
    expect(await deliver(renewal.notification)).toBe("processed");

    clock.set(E + 3 * DAY);
    expect(await deliver(apple.refund(purchase.originalTransactionId, purchase.transactionId))).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId))
      .toMatchObject({ status: "active", last_transaction_id: renewal.transactionId, revoked_at: null });
    const refunded = () => transactionRows().then((rows) => rows.find((row) => row.transaction_id === purchase.transactionId));
    expect((await refunded())?.revoked_at).not.toBeNull();
    await expectPlan("user-a", "pro");

    // With the Server API down the service cannot ask Apple for the current
    // period, so the store's forward-only write alone must keep the refund
    // of a past period from revoking the current one.
    clock.set(E + 4 * DAY);
    const reversal = apple.reverseRefund(purchase.originalTransactionId, purchase.transactionId);
    clock.advance(MINUTE);
    const refundAgain = apple.refund(purchase.originalTransactionId, purchase.transactionId);
    apple.serverApiOutage = true;
    expect(await deliver(reversal)).toBe("processed");
    expect((await refunded())?.revoked_at).toBeNull();
    expect(await deliver(refundAgain)).toBe("processed");
    apple.serverApiOutage = false;
    expect((await refunded())?.revoked_at).not.toBeNull();
    expect(await subscriptionRow(purchase.originalTransactionId))
      .toMatchObject({ status: "active", last_transaction_id: renewal.transactionId, revoked_at: null });
    await expectPlan("user-a", "pro");
  });

  dbTest("9a. an upgrade to Max applies at once; a downgrade to Pro keeps Max until the paid period ends", async () => {
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

    // Apple charges the Pro renewal up to a day early; the Max month is still paid for.
    const maxEnds = T0 + 3 * DAY + SUBSCRIPTION_PERIOD_MS;
    clock.set(maxEnds - 20 * HOUR);
    const renewal = apple.renew(purchase.originalTransactionId);
    expect(await deliver(renewal.notification)).toBe("processed");
    expect(await subscriptionRow(purchase.originalTransactionId)).toMatchObject({ plan_id: "pro", product_id: "com.cmux.app.pro.monthly" });
    await expectPlan("user-a", "max");
    const runs = await cronEveryHalfHour(maxEnds - 6 * HOUR, maxEnds - 30 * MINUTE, "user-a", "max");
    expect(runs.every((run) => run.ok)).toBe(true);

    // The first cron after the Max period ends re-derives the mirror to Pro.
    clock.set(maxEnds + 20 * MINUTE);
    await runCron();
    await expectPlan("user-a", "pro");
    clock.set(maxEnds + DAY);
    await expectPlan("user-a", "pro");
    expect(accounts.get("user-a")!.writes).toEqual([{ cmuxPlan: "pro" }, { cmuxPlan: "max" }, { cmuxPlan: "pro" }]);
  });

  dbTest("9b. an upgrade to Max after Apple already charged the next Pro period grants Max at once", async () => {
    const { purchase } = await buyProAndPost();

    clock.set(E - 20 * HOUR);
    const renewal = apple.renew(purchase.originalTransactionId); // the next period starts at E
    expect(await deliver(renewal.notification)).toBe("processed");
    await expectPlan("user-a", "pro");

    clock.set(E - 10 * HOUR);
    const upgrade = apple.upgrade(purchase.originalTransactionId, "max");
    const response = await app.postTransaction("user-a", upgrade.jws);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ planId: "max", status: "active" });
    await expectPlan("user-a", "max");
    expect(await subscriptionRow(purchase.originalTransactionId))
      .toMatchObject({ plan_id: "max", last_transaction_id: upgrade.transactionId });

    clock.advance(MINUTE);
    expect(await deliver(upgrade.notification)).toBe("processed");
    await expectPlan("user-a", "max");
    await cronEveryHalfHour(E - 6 * HOUR, E + HOUR, "user-a", "max");
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
    clock.set(E - HOUR);
    const renewal = apple.renew(purchase.originalTransactionId);
    clock.set(E + 2 * DAY);
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
    expect(grantInsertIds()).toEqual([`apple_entitlement:${upgrade.transactionId}`]);
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
    expect(billingErrors).toHaveLength(1); // the webhook 503 is reported
    billingErrors.length = 0;

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

  dbTest("15. a renewal Apple charges late in billing retry, with every notification lost: the sweep asks Apple and restores Pro", async () => {
    const { purchase } = await buyProAndPost();

    // At expiry the charge fails with no grace period; Apple's notifications never arrive.
    clock.set(E);
    apple.omitFromHistory(apple.failRenewal(purchase.originalTransactionId, { graceDays: 0 }));
    const first = await runCron(); // re-check: Apple says billing retry, nothing to write
    expect(first).toMatchObject({ renewalsChecked: 1, renewalsExtended: 0 });
    expectMirror("user-a", "pro");

    clock.set(E + 30 * MINUTE);
    await runCron();
    // A plan read in billing retry shows free (correct: Apple has not been paid).
    expect((await readPlan("user-a")).subscriptionPlanId).toBe("free");
    expectMirror("user-a", "free");

    clock.set(E + 70 * MINUTE);
    const recovery = apple.recoverBilling(purchase.originalTransactionId);
    apple.omitFromHistory(recovery.notification);

    clock.set(E + 90 * MINUTE);
    const sweep = await runCron();
    expect({ lapsesRecovered: sweep.lapsesRecovered, lapsedUsers: sweep.lapsedUsers }).toEqual({ lapsesRecovered: 1, lapsedUsers: 0 });
    expect(await subscriptionRow(purchase.originalTransactionId))
      .toMatchObject({ status: "active", last_transaction_id: recovery.transactionId });
    await expectPlan("user-a", "pro");
    expect(accounts.get("user-a")!.writes).toEqual([{ cmuxPlan: "pro" }, {}, { cmuxPlan: "pro" }]);
  });

  dbTest("16. the Server API down at expiry: the sweep defers the lapse, then expires it on Apple's last signed state after a day", async () => {
    const { purchase } = await buyProAndPost();
    clock.set(T0 + 10 * DAY);
    expect(await deliver(apple.setAutoRenew(purchase.originalTransactionId, false))).toBe("processed");

    clock.set(E);
    apple.omitFromHistory(apple.expire(purchase.originalTransactionId));
    apple.serverApiOutage = true;
    clock.set(E + 90 * MINUTE);
    const deferred = await runCron({ expectOk: false }); // the history read fails too
    expect({ lapsedDeferred: deferred.lapsedDeferred, lapsedUsers: deferred.lapsedUsers }).toEqual({ lapsedDeferred: 1, lapsedUsers: 0 });
    expect(deferred.history.failures).toBeGreaterThan(0);
    expectMirror("user-a", "pro");

    clock.set(E + DAY + 31 * MINUTE);
    const expired = await runCron({ expectOk: false });
    expect({ lapsedDeferred: expired.lapsedDeferred, lapsedUsers: expired.lapsedUsers }).toEqual({ lapsedDeferred: 0, lapsedUsers: 1 });
    expectMirror("user-a", "free");
    apple.serverApiOutage = false;
    await expectPlan("user-a", "free");
    expect(billingErrors.length).toBe(2); // one history failure report per run
    billingErrors.length = 0;
  });

  dbTest("17. applying a notification fails while Stack is down: 200 to Apple, retried with backoff, then granted", async () => {
    const token = await app.accountToken("user-a");
    const purchase = apple.purchase({ token, plan: "pro" });

    clock.advance(MINUTE);
    stackLookupFailures = 1;
    expect(await deliver(purchase.notification)).toBe("failed");
    const failed = await ledgerRow(purchase.notification.uuid);
    expect(failed).toMatchObject({ processed_at: null, attempt_count: 1 });
    expect(failed!.next_attempt_at?.getTime()).toBe(clock.now() + 5 * MINUTE);
    expectMirror("user-a", "free");

    clock.advance(2 * MINUTE);
    expect((await runCron()).notifications.processed).toBe(0); // not due yet
    expectMirror("user-a", "free");

    clock.advance(4 * MINUTE);
    expect((await runCron()).notifications.processed).toBe(1);
    expect((await ledgerRow(purchase.notification.uuid))?.processed_at).not.toBeNull();
    await expectPlan("user-a", "pro");
  });

  dbTest("18. Stripe and Apple together: the higher plan wins, and an Apple refund falls back to Stripe Pro", async () => {
    await sql!`insert into stripe_customers (id, stack_user_id) values ('cus_e2e', 'user-a')`;
    await sql!`insert into stripe_subscriptions (id, customer_id, stack_user_id, status, plan, scope, current_period_end)
      values ('sub_e2e', 'cus_e2e', 'user-a', 'active', 'pro', 'user', ${new Date(T0 + 20 * DAY)})`;
    accounts.get("user-a")!.metadata = { cmuxPlan: "pro" };
    await expectPlan("user-a", "pro", "stripe");

    const token = await app.accountToken("user-a");
    const purchase = apple.purchase({ token, plan: "max" });
    clock.advance(MINUTE);
    expect((await app.postTransaction("user-a", purchase.jws)).status).toBe(200);
    await expectPlan("user-a", "max", "apple");

    clock.set(T0 + 3 * DAY);
    expect(await deliver(apple.refund(purchase.originalTransactionId))).toBe("processed");
    await expectPlan("user-a", "pro", "stripe");
    expect(accounts.get("user-a")!.writes).toEqual([{ cmuxPlan: "max" }, { cmuxPlan: "pro" }]);
  });
});
