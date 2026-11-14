// Database-backed proof that deleting a cmux account drops its link to its
// App Store subscriptions: the pre-delete check sees the renewing
// subscription, deletion removes the token and the subscription state,
// keeps the transaction ledger under the deleted-account placeholder, and a
// later App Store notification for that subscription is skipped as unlinked
// instead of granting a plan to the deleted account.
// Gated like the other *-db-behavior tests.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests, cloudDb } from "../db/client";
import {
  accountDeletionCheckForUser,
  detachAppleBillingForAccountDeletion,
} from "../services/billing/apple/accountDeletion";
import { processAppleNotification, type AppleIapDependencies } from "../services/billing/apple/service";
import type { AppleSubscriptionState } from "../services/billing/apple/state";
import { databaseAppleIapStore } from "../services/billing/apple/store";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const store = databaseAppleIapStore();
const NOW = Date.now();
const DAY = 24 * 60 * 60 * 1000;
const USER = "deleting-user";

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate apple_account_tokens, apple_subscriptions, apple_transactions, apple_notifications`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

function state(token: string, overrides: Partial<AppleSubscriptionState> = {}): AppleSubscriptionState {
  return {
    originalTransactionId: "otx-deleted",
    appAccountToken: token,
    bundleId: "com.cmux.app",
    environment: "Production",
    productId: "com.cmux.app.pro.monthly",
    planId: "pro",
    status: "active",
    autoRenewEnabled: true,
    autoRenewProductId: "com.cmux.app.pro.monthly",
    purchaseDate: new Date(NOW - DAY),
    originalPurchaseDate: new Date(NOW - DAY),
    expiresAt: new Date(NOW + 29 * DAY),
    gracePeriodExpiresAt: null,
    storefront: "USA",
    currency: "USD",
    priceMilliunits: 74990,
    lastTransactionId: "tx-1",
    revokedAt: null,
    revocationReason: null,
    stateSignedAt: new Date(NOW - DAY),
    ...overrides,
  };
}

async function subscribe(): Promise<string> {
  const token = await store.accountTokenForUser(USER);
  await store.writeSubscriptionState(state(token), { tokenOwner: USER });
  await store.recordTransaction({
    transactionId: "tx-1",
    originalTransactionId: "otx-deleted",
    userId: USER,
    productId: "com.cmux.app.pro.monthly",
    planId: "pro",
    environment: "Production",
    type: "PURCHASE",
    purchaseDate: new Date(NOW - DAY),
    expiresAt: new Date(NOW + 29 * DAY),
    priceMilliunits: 74990,
    currency: "USD",
    storefront: "USA",
    offerType: null,
    revokedAt: null,
    payload: {},
  });
  return token;
}

describe("account deletion with an App Store subscription", () => {
  dbTest("the pre-delete check reports a renewing subscription and stops once auto-renew is off", async () => {
    const token = await subscribe();
    expect(await accountDeletionCheckForUser(USER)).toEqual({
      appStoreSubscriptionRenews: true,
      manageSubscriptionsUrl: "https://apps.apple.com/account/subscriptions",
    });
    await store.writeSubscriptionState(
      state(token, { autoRenewEnabled: false, stateSignedAt: new Date(NOW) }),
      { tokenOwner: USER },
    );
    expect(await accountDeletionCheckForUser(USER)).toEqual({
      appStoreSubscriptionRenews: false,
      manageSubscriptionsUrl: null,
    });
  });

  dbTest("deletion leaves other accounts' tokens, subscriptions and ledger rows alone", async () => {
    await subscribe();
    const otherToken = await store.accountTokenForUser("other-user");
    await store.writeSubscriptionState(
      state(otherToken, { originalTransactionId: "otx-other", lastTransactionId: "tx-other" }),
      { tokenOwner: "other-user" },
    );
    await store.recordTransaction({
      transactionId: "tx-other",
      originalTransactionId: "otx-other",
      userId: "other-user",
      productId: "com.cmux.app.pro.monthly",
      planId: "pro",
      environment: "Production",
      type: "PURCHASE",
      purchaseDate: new Date(NOW - DAY),
      expiresAt: new Date(NOW + 29 * DAY),
      priceMilliunits: 74990,
      currency: "USD",
      storefront: "USA",
      offerType: null,
      revokedAt: null,
      payload: {},
    });

    await cloudDb().transaction((tx) => detachAppleBillingForAccountDeletion(tx, USER));

    expect(await store.userIdForAccountToken(otherToken)).toBe("other-user");
    expect(await store.subscription("otx-other")).toMatchObject({ userId: "other-user", status: "active" });
    const otherLedger = await sql!`select user_id from apple_transactions where transaction_id = 'tx-other'`;
    expect(otherLedger.map((row) => row.user_id)).toEqual(["other-user"]);
    expect(await accountDeletionCheckForUser("other-user")).toMatchObject({ appStoreSubscriptionRenews: true });
  });

  dbTest("deletion unlinks the subscription, keeps the ledger, and a later renewal is skipped", async () => {
    const token = await subscribe();

    await cloudDb().transaction((tx) => detachAppleBillingForAccountDeletion(tx, USER));

    expect(await store.userIdForAccountToken(token)).toBeNull();
    expect(await store.subscription("otx-deleted")).toBeNull();
    expect(await accountDeletionCheckForUser(USER)).toMatchObject({ appStoreSubscriptionRenews: false });
    const ledger = await sql!`select user_id from apple_transactions where transaction_id = 'tx-1'`;
    expect(ledger.map((row) => row.user_id)).toEqual(["deleted-account"]);

    // Apple keeps renewing the subscription; its next notification still
    // carries the deleted account's token.
    const { row } = await store.insertNotification({
      notificationUuid: "renewal-after-deletion",
      notificationType: "DID_RENEW",
      subtype: null,
      environment: "Production",
      originalTransactionId: "otx-deleted",
      signedDate: new Date(NOW),
      payload: {
        data: {
          transactionInfo: {
            type: "Auto-Renewable Subscription",
            originalTransactionId: "otx-deleted",
            transactionId: "tx-2",
            appAccountToken: token,
            bundleId: "com.cmux.app",
            productId: "com.cmux.app.pro.monthly",
            environment: "Production",
            purchaseDate: NOW,
            expiresDate: NOW + 30 * DAY,
            signedDate: NOW,
          },
        },
      },
    });
    const applied: string[] = [];
    const deps: AppleIapDependencies = {
      store,
      verifier: {} as AppleIapDependencies["verifier"],
      serverApi: null,
      applyEntitlement: async (userId) => { applied.push(userId); },
      captureEvent: async () => {},
      now: () => new Date(NOW),
    };

    expect(await processAppleNotification(row, deps)).toBe("skipped");
    expect(applied).toEqual([]);
    expect(await store.subscription("otx-deleted")).toBeNull();
    const [ledgerRow] = await sql!`select processed_at, error from apple_notifications where notification_uuid = 'renewal-after-deletion'`;
    expect(ledgerRow?.processed_at).not.toBeNull();
    expect(ledgerRow?.error).toBe("skipped: unlinked_account");
  });
});
