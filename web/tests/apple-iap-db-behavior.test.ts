// Database-backed proof of the Apple IAP store contract the in-memory store
// mirrors: one account token per user, forward-only subscription state,
// ownership pinned to the first user, and an idempotent notification ledger.
// Gated like the other *-db-behavior tests.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { activeApplePlanForUser } from "../services/billing/apple/entitlement";
import type { AppleSubscriptionState } from "../services/billing/apple/state";
import {
  APPLE_NOTIFICATION_MAX_ATTEMPTS,
  AppleOwnershipError,
  appleNotificationRetryDelayMs,
  databaseAppleIapStore,
} from "../services/billing/apple/store";

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
  await sql`truncate apple_account_tokens, apple_subscriptions, apple_transactions, apple_notifications, apple_notification_history_cursors`;
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

  dbTest("an older signed copy of a transaction never replaces a newer one", async () => {
    const row = {
      transactionId: "tx-1", originalTransactionId: "otx-1", userId: "user-a", productId: "com.cmux.app.pro.monthly",
      planId: "pro", environment: "Production", type: "PURCHASE", purchaseDate: new Date(NOW), expiresAt: null,
      priceMilliunits: 74990, currency: "USD", storefront: "USA", offerType: null, revokedAt: null,
    };
    await store.recordTransaction({ ...row, revokedAt: new Date(NOW), payload: { signedDate: NOW } });
    await store.recordTransaction({ ...row, payload: { signedDate: NOW - DAY } });
    const [refunded] = await sql!`select revoked_at, payload from apple_transactions`;
    expect(refunded!.revoked_at).not.toBeNull();
    expect(Number(refunded!.payload.signedDate)).toBe(NOW);
    // A newer copy (a refund reversal) still applies.
    await store.recordTransaction({ ...row, payload: { signedDate: NOW + 1000 } });
    const [reversed] = await sql!`select revoked_at from apple_transactions`;
    expect(reversed!.revoked_at).toBeNull();
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
    await store.markNotificationFailed("n-1", "Stack unavailable", new Date(NOW));
    await store.markNotificationProcessed("n-2", new Date());
    await store.markNotificationSkipped("n-3", "unlinked_account", new Date());
    const due = new Date(NOW + appleNotificationRetryDelayMs(1));
    expect((await store.pendingNotifications(10, due)).map((row) => row.notificationUuid)).toEqual(["n-1"]);
    await store.markNotificationProcessed("n-1", new Date());
    expect(await store.pendingNotifications(10, due)).toEqual([]);
  });

  dbTest("a failed notification backs off exponentially and is dead-lettered after the last attempt", async () => {
    const ledger = {
      notificationUuid: "n-1", notificationType: "DID_RENEW", subtype: null, environment: "Production",
      originalTransactionId: "otx-1", signedDate: new Date(NOW), payload: { data: {} },
    };
    await store.insertNotification(ledger);
    await store.insertNotification({ ...ledger, notificationUuid: "n-2" });
    const first = await store.markNotificationFailed("n-1", "boom", new Date(NOW));
    expect(first).toEqual({ attemptCount: 1, deadLettered: false });
    const [row] = await sql!`select attempt_count, next_attempt_at, dead_lettered_at from apple_notifications where notification_uuid = 'n-1'`;
    expect(new Date(row!.next_attempt_at).getTime()).toBe(NOW + appleNotificationRetryDelayMs(1));
    // Not due yet: only the untouched row is listed.
    expect((await store.pendingNotifications(10, new Date(NOW))).map((r) => r.notificationUuid)).toEqual(["n-2"]);
    const second = await store.markNotificationFailed("n-1", "boom", new Date(NOW));
    expect(second.attemptCount).toBe(2);
    const [again] = await sql!`select next_attempt_at from apple_notifications where notification_uuid = 'n-1'`;
    expect(new Date(again!.next_attempt_at).getTime()).toBe(NOW + appleNotificationRetryDelayMs(2));
    let last = second;
    for (let attempt = 3; attempt <= APPLE_NOTIFICATION_MAX_ATTEMPTS; attempt += 1) {
      last = await store.markNotificationFailed("n-1", "boom", new Date(NOW));
    }
    expect(last).toEqual({ attemptCount: APPLE_NOTIFICATION_MAX_ATTEMPTS, deadLettered: true });
    const far = new Date(NOW + 365 * DAY);
    expect((await store.pendingNotifications(10, far)).map((r) => r.notificationUuid)).toEqual(["n-2"]);
    expect((await store.notification("n-1"))?.deadLetteredAt).not.toBeNull();
  });

  dbTest("renewal re-check candidates: granting, auto-renewing, ending in the window, not checked recently", async () => {
    const write = (overrides: Partial<AppleSubscriptionState>) =>
      store.writeSubscriptionState(state(overrides), { tokenOwner: "user-a" });
    const HOUR = 60 * 60_000;
    await write({ originalTransactionId: "soon", expiresAt: new Date(NOW + 2 * HOUR) });
    await write({ originalTransactionId: "sooner", expiresAt: new Date(NOW + HOUR) });
    await write({ originalTransactionId: "far", expiresAt: new Date(NOW + 10 * DAY) });
    await write({ originalTransactionId: "off", autoRenewEnabled: false, expiresAt: new Date(NOW + HOUR) });
    await write({ originalTransactionId: "unknown-renew", autoRenewEnabled: null, expiresAt: new Date(NOW + 3 * HOUR) });
    await write({ originalTransactionId: "expired", status: "expired", expiresAt: new Date(NOW + HOUR) });
    await write({ originalTransactionId: "long-gone", expiresAt: new Date(NOW - 2 * HOUR) });
    await write({
      originalTransactionId: "grace", status: "grace_period",
      expiresAt: new Date(NOW - DAY), gracePeriodExpiresAt: new Date(NOW + 4 * HOUR),
    });
    await write({ originalTransactionId: "checked", expiresAt: new Date(NOW + HOUR) });
    const before = await store.subscription("checked");
    await store.markAppleChecked("checked", new Date(NOW));
    const after = await store.subscription("checked");
    expect(after?.appleCheckedAt?.getTime()).toBe(NOW);
    expect(after?.updatedAt.getTime()).toBe(before?.updatedAt.getTime());

    const query = {
      accessEndsAfter: new Date(NOW - HOUR),
      accessEndsBy: new Date(NOW + 6 * HOUR),
      checkedBefore: new Date(NOW - 25 * 60_000),
      limit: 10,
    };
    expect((await store.renewalCheckCandidates(query)).map((row) => row.originalTransactionId))
      .toEqual(["sooner", "soon", "unknown-renew", "grace"]);
    expect((await store.renewalCheckCandidates({ ...query, checkedBefore: new Date(NOW + 1) })).map((row) => row.originalTransactionId))
      .toEqual(["checked", "sooner", "soon", "unknown-renew", "grace"]);
    expect(await store.renewalCheckCandidates({ ...query, limit: 1 })).toHaveLength(1);
  });

  dbTest("the history cursor upserts per bundle and environment", async () => {
    expect(await store.notificationHistoryCursor("com.cmux.app", "Production")).toBeNull();
    const cursor = {
      bundleId: "com.cmux.app", environment: "Production", nextStartAt: new Date(NOW - DAY),
      windowStartAt: new Date(NOW - DAY), windowEndAt: new Date(NOW), paginationToken: "page-2",
    };
    await store.saveNotificationHistoryCursor(cursor);
    await store.saveNotificationHistoryCursor({ ...cursor, environment: "Sandbox", paginationToken: null });
    expect(await store.notificationHistoryCursor("com.cmux.app", "Production")).toEqual(cursor);
    const done = { ...cursor, nextStartAt: new Date(NOW), windowStartAt: null, windowEndAt: null, paginationToken: null };
    await store.saveNotificationHistoryCursor(done);
    expect(await store.notificationHistoryCursor("com.cmux.app", "Production")).toEqual(done);
    expect((await store.notificationHistoryCursor("com.cmux.app", "Sandbox"))?.paginationToken).toBeNull();
  });

  dbTest("the newest ledger signed date is per environment", async () => {
    expect(await store.latestNotificationSignedDate("Production")).toBeNull();
    const ledger = {
      notificationUuid: "n-1", notificationType: "DID_RENEW", subtype: null, environment: "Production",
      originalTransactionId: "otx-1", signedDate: new Date(NOW - DAY), payload: { data: {} },
    };
    await store.insertNotification(ledger);
    await store.insertNotification({ ...ledger, notificationUuid: "n-2", signedDate: new Date(NOW) });
    await store.insertNotification({ ...ledger, notificationUuid: "n-3", environment: "Sandbox", signedDate: new Date(NOW + DAY) });
    expect((await store.latestNotificationSignedDate("Production"))?.getTime()).toBe(NOW);
    expect((await store.latestNotificationSignedDate("Sandbox"))?.getTime()).toBe(NOW + DAY);
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
    expect(lapsed[2]).toMatchObject({
      originalTransactionId: "otx-a", bundleId: "com.cmux.app", environment: "Production", appleCheckedAt: null,
    });
    // An earlier cutoff (the sweep's leeway) leaves out the row that lapsed a minute ago.
    expect((await store.lapsedSubscriptions(new Date(NOW - 30 * 60_000), 10)).map((row) => row.userId))
      .toEqual(["user-e", "user-b"]);
    await store.markLapseSwept(lapsed.map((row) => row.originalTransactionId), new Date(NOW));
    expect(await store.lapsedSubscriptions(new Date(NOW), 10)).toEqual([]);
    const statuses = await sql!`select original_transaction_id, status from apple_subscriptions order by original_transaction_id`;
    expect(statuses.map((row) => [row.original_transaction_id, row.status])).toEqual([
      ["otx-a", "expired"], ["otx-b", "billing_retry"], ["otx-c", "grace_period"], ["otx-d", "expired"], ["otx-e", "billing_retry"],
    ]);
  });
});
