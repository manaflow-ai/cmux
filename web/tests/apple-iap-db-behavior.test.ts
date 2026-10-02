// Database-backed proof of the Apple IAP store contract the in-memory store
// mirrors: one account token per user, forward-only subscription state,
// ownership pinned to the first user, and an idempotent notification ledger.
// Gated like the other *-db-behavior tests.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { activeApplePlanForUser } from "../services/billing/apple/entitlement";
import type { AppleSubscriptionState } from "../services/billing/apple/state";
import { AppleOwnershipError, databaseAppleIapStore } from "../services/billing/apple/store";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const store = databaseAppleIapStore();
const NOW = Date.now();
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
  await sql`truncate apple_account_tokens, apple_subscriptions, apple_transactions, apple_notifications`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

function state(overrides: Partial<AppleSubscriptionState> = {}): AppleSubscriptionState {
  return {
    originalTransactionId: "otx-1",
    appAccountToken: null,
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

describe("Apple IAP store", () => {
  dbTest("mints one stable account token per user and resolves it back", async () => {
    const first = await store.accountTokenForUser("user-a");
    expect(await store.accountTokenForUser("user-a")).toBe(first);
    expect(await store.accountTokenForUser("user-b")).not.toBe(first);
    expect(await store.userIdForAccountToken(first.toUpperCase())).toBe("user-a");
  });

  dbTest("subscription state only moves forward in signed-date order", async () => {
    expect((await store.writeSubscriptionState(state(), { tokenOwner: "user-a" })).applied).toBe(true);
    const expired = state({ status: "expired", stateSignedAt: new Date(NOW) });
    expect((await store.writeSubscriptionState(expired, { tokenOwner: "user-a" })).applied).toBe(true);
    const stale = await store.writeSubscriptionState(state({ status: "active", stateSignedAt: new Date(NOW - 1000) }), { tokenOwner: "user-a" });
    expect(stale.applied).toBe(false);
    expect((await store.subscription("otx-1"))?.status).toBe("expired");
  });

  dbTest("a newer-signed state about an older transaction never overwrites the current one", async () => {
    await store.writeSubscriptionState(state({ lastTransactionId: "tx-2", purchaseDate: new Date(NOW - DAY) }), { tokenOwner: "user-a" });
    const refundOfOlder = await store.writeSubscriptionState(state({
      lastTransactionId: "tx-1", purchaseDate: new Date(NOW - 31 * DAY), expiresAt: new Date(NOW - DAY),
      status: "revoked", revokedAt: new Date(NOW), stateSignedAt: new Date(NOW),
    }), { tokenOwner: "user-a" });
    expect(refundOfOlder.applied).toBe(false);
    expect(await store.subscription("otx-1")).toMatchObject({ lastTransactionId: "tx-2", status: "active" });
    const refundOfCurrent = await store.writeSubscriptionState(state({
      lastTransactionId: "tx-2", purchaseDate: new Date(NOW - DAY), status: "revoked", revokedAt: new Date(NOW),
      stateSignedAt: new Date(NOW + 1000),
    }), { tokenOwner: "user-a" });
    expect(refundOfCurrent.applied).toBe(true);
    expect((await store.subscription("otx-1"))?.status).toBe("revoked");
  });

  dbTest("concurrent writers for one subscription serialize", async () => {
    const writes = await Promise.all(Array.from({ length: 8 }, (_, index) =>
      store.writeSubscriptionState(state({ stateSignedAt: new Date(NOW + index), lastTransactionId: `tx-${index}` }), { tokenOwner: "user-a" })
    ));
    expect(writes.filter((write) => write.applied).length).toBeGreaterThan(0);
    expect((await store.subscription("otx-1"))?.lastTransactionId).toBe("tx-7");
  });

  dbTest("only a newer transaction carrying a user's token moves a subscription to that user", async () => {
    await store.writeSubscriptionState(state(), { tokenOwner: "user-a" });
    // Token-less, or the same transaction again: the owner never changes.
    await expect(store.writeSubscriptionState(state({ stateSignedAt: new Date(NOW) }), { tokenOwner: null, caller: "user-b" }))
      .rejects.toBeInstanceOf(AppleOwnershipError);
    await expect(store.writeSubscriptionState(state({ stateSignedAt: new Date(NOW) }), { tokenOwner: "user-b", caller: "user-b" }))
      .rejects.toBeInstanceOf(AppleOwnershipError);
    const moved = await store.writeSubscriptionState(
      state({ lastTransactionId: "tx-2", purchaseDate: new Date(NOW), stateSignedAt: new Date(NOW), planId: "max" }),
      { tokenOwner: "user-b", caller: "user-b" },
    );
    expect(moved).toMatchObject({ applied: true, transferredFrom: "user-a" });
    expect(await store.subscription("otx-1")).toMatchObject({ userId: "user-b", planId: "max" });
  });

  dbTest("the entitlement query grants only unexpired active rows, highest plan first", async () => {
    await store.writeSubscriptionState(state(), { tokenOwner: "user-a" });
    await store.writeSubscriptionState(state({ originalTransactionId: "otx-2", planId: "max", status: "expired" }), { tokenOwner: "user-a" });
    expect(await activeApplePlanForUser("user-a")).toBe("pro");
    await store.writeSubscriptionState(state({ status: "revoked", stateSignedAt: new Date(NOW) }), { tokenOwner: "user-a" });
    expect(await activeApplePlanForUser("user-a")).toBeNull();
  });

  dbTest("transactions upsert by id and keep refunds", async () => {
    const row = {
      transactionId: "tx-1", originalTransactionId: "otx-1", userId: "user-a", productId: "com.cmux.app.pro.monthly",
      planId: "pro", environment: "Production", type: "PURCHASE", purchaseDate: new Date(NOW), expiresAt: null,
      priceMilliunits: 74990, currency: "USD", storefront: "USA", offerType: null, revokedAt: null, payload: { a: 1 },
    };
    await store.recordTransaction(row);
    await store.recordTransaction({ ...row, revokedAt: new Date(NOW) });
    const rows = await sql!`select revoked_at, price_milliunits from apple_transactions`;
    expect(rows).toHaveLength(1);
    expect(rows[0]!.revoked_at).not.toBeNull();
    expect(Number(rows[0]!.price_milliunits)).toBe(74990);
  });

  dbTest("the notification ledger is idempotent and lists only unfinished rows", async () => {
    const ledger = {
      notificationUuid: "n-1", notificationType: "DID_RENEW", subtype: null, environment: "Production",
      originalTransactionId: "otx-1", signedDate: new Date(NOW), payload: { data: {} },
    };
    expect((await store.insertNotification(ledger)).inserted).toBe(true);
    expect((await store.insertNotification(ledger)).inserted).toBe(false);
    await store.insertNotification({ ...ledger, notificationUuid: "n-2" });
    await store.insertNotification({ ...ledger, notificationUuid: "n-3" });
    await store.markNotificationFailed("n-1", "Stack unavailable");
    await store.markNotificationProcessed("n-2", new Date());
    await store.markNotificationSkipped("n-3", "unlinked_account", new Date());
    expect((await store.pendingNotifications(10)).map((row) => row.notificationUuid)).toEqual(["n-1"]);
    await store.markNotificationProcessed("n-1", new Date());
    expect(await store.pendingNotifications(10)).toEqual([]);
  });

  dbTest("the lapse sweep lists rows past expiry and grace, oldest lapse first, until swept", async () => {
    const write = (overrides: Partial<AppleSubscriptionState>, userId: string) =>
      store.writeSubscriptionState(state(overrides), { tokenOwner: userId });
    await write({ originalTransactionId: "otx-a", expiresAt: new Date(NOW - 60_000) }, "user-a");
    await write({
      originalTransactionId: "otx-b", status: "grace_period",
      expiresAt: new Date(NOW - 20 * DAY), gracePeriodExpiresAt: new Date(NOW - 60 * 60_000),
    }, "user-b");
    await write({
      originalTransactionId: "otx-c", status: "grace_period",
      expiresAt: new Date(NOW - 20 * DAY), gracePeriodExpiresAt: new Date(NOW + DAY),
    }, "user-c");
    await write({ originalTransactionId: "otx-d", status: "expired", expiresAt: new Date(NOW - 60_000) }, "user-d");
    await write({
      originalTransactionId: "otx-e", status: "billing_retry",
      expiresAt: new Date(NOW - 40 * DAY), gracePeriodExpiresAt: new Date(NOW - 10 * DAY),
    }, "user-e");
    // The rows were last written before they lapsed.
    await sql!`update apple_subscriptions set updated_at = now() - interval '60 days'`;

    const lapsed = await store.lapsedSubscriptions(new Date(NOW), 10);
    expect(lapsed.map((row) => row.userId)).toEqual(["user-e", "user-b", "user-a"]);
    await store.markLapseSwept(lapsed.map((row) => row.originalTransactionId), new Date(NOW));
    expect(await store.lapsedSubscriptions(new Date(NOW), 10)).toEqual([]);
    const statuses = await sql!`select original_transaction_id, status from apple_subscriptions order by original_transaction_id`;
    expect(statuses.map((row) => [row.original_transaction_id, row.status])).toEqual([
      ["otx-a", "expired"], ["otx-b", "billing_retry"], ["otx-c", "grace_period"], ["otx-d", "expired"], ["otx-e", "billing_retry"],
    ]);
  });
});
