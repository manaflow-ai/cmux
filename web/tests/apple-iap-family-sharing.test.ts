// Only the purchaser gets the plan. A Family Sharing transaction
// (`inAppOwnershipType: FAMILY_SHARED`) never grants, claims or changes a
// subscription, whichever path brings it in: the app posting it, a
// notification, the history backfill, or a renewal re-check. It is recorded in
// apple_transactions for audit only.

import { beforeEach, describe, expect, test } from "bun:test";

import { appleSubscriptionGrantsAccess } from "../services/billing/apple/entitlement";
import { backfillAppleNotifications } from "../services/billing/apple/history";
import {
  AppleTransactionRejectedError,
  receiveAppleNotification,
  recordClientAppleTransaction,
  retryAppleNotifications,
} from "../services/billing/apple/service";
import {
  DAY,
  HOUR,
  NOW,
  ORIGINAL,
  createFixture,
  notification,
  renewal,
  seedSubscription,
  signer,
  transaction,
  type Fixture,
} from "./helpers/apple-iap-fixture";

let f: Fixture;

beforeEach(async () => {
  f = await createFixture();
});

function familyTransaction(overrides: Record<string, unknown> = {}, token?: string) {
  return transaction({
    transactionId: "family-1",
    inAppOwnershipType: "FAMILY_SHARED",
    purchaseDate: NOW.getTime() - DAY,
    expiresDate: NOW.getTime() + 29 * DAY,
    signedDate: NOW.getTime(),
    ...overrides,
  }, token);
}

function purchaserGrants(): boolean {
  return appleSubscriptionGrantsAccess(f.subscription(), NOW, {});
}

async function rejection(promise: Promise<unknown>): Promise<string | null> {
  try {
    await promise;
    return null;
  } catch (error) {
    return error instanceof AppleTransactionRejectedError ? error.reason : `unexpected: ${String(error)}`;
  }
}

describe("app-posted transactions", () => {
  test("a family-shared transaction is refused with family_shared and grants nothing", async () => {
    const reason = await rejection(recordClientAppleTransaction({
      userId: "user-b",
      signedTransactionInfo: signer.sign(familyTransaction({ originalTransactionId: "family-original" })),
    }, f.deps()));
    expect(reason).toBe("family_shared");
    expect(f.store.subscriptions.size).toBe(0);
    expect(f.applied).toEqual([]);
    // Kept for audit, attributed to the account that posted it.
    expect(f.store.transactions.get("family-1")).toMatchObject({ userId: "user-b", originalTransactionId: "family-original" });
  });

  test("a family member posting the purchaser's family-shared transaction cannot claim or change it", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() + 20 * DAY) });
    const before = f.subscription();
    const reason = await rejection(recordClientAppleTransaction({
      userId: "user-b",
      signedTransactionInfo: signer.sign(familyTransaction({ purchaseDate: NOW.getTime() }, f.tokenB)),
    }, f.deps()));
    expect(reason).toBe("family_shared");
    expect(f.subscription()).toEqual(before);
    expect(f.applied).toEqual([]);
  });

  test("a family-shared transaction carrying the caller's own token is still refused", async () => {
    const reason = await rejection(recordClientAppleTransaction({
      userId: "user-a",
      signedTransactionInfo: signer.sign(familyTransaction({}, f.token)),
    }, f.deps()));
    expect(reason).toBe("family_shared");
    expect(f.store.subscriptions.size).toBe(0);
  });

  test("a purchased transaction still grants", async () => {
    const result = await recordClientAppleTransaction({
      userId: "user-a",
      signedTransactionInfo: signer.sign(transaction({ inAppOwnershipType: "PURCHASED", expiresDate: NOW.getTime() + 29 * DAY }, f.token)),
    }, f.deps());
    expect(result.status).toBe("active");
    expect(f.applied).toEqual(["user-a"]);
  });
});

describe("notifications", () => {
  test("SUBSCRIBED for a family-shared transaction is closed as skipped: family_shared", async () => {
    const outcome = await receiveAppleNotification(notification({
      type: "SUBSCRIBED", subtype: "INITIAL_BUY", status: 1, signedDate: NOW.getTime(),
      tx: familyTransaction({ originalTransactionId: "family-original" }, f.tokenB),
    }), f.deps());
    expect(outcome).toBe("skipped");
    expect([...f.store.notifications.values()][0]?.error).toBe("skipped: family_shared");
    expect(f.store.subscriptions.size).toBe(0);
    expect(f.applied).toEqual([]);
    expect(f.store.transactions.get("family-1")?.userId).toBe("user-b");
  });

  test("a REVOKE for a family-shared transaction does not touch the purchaser's subscription", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() + 20 * DAY) });
    const before = f.subscription();
    const outcome = await receiveAppleNotification(notification({
      type: "REVOKE", status: 5, signedDate: NOW.getTime(),
      tx: familyTransaction({ revocationDate: NOW.getTime() }),
    }), f.deps());
    expect(outcome).toBe("skipped");
    expect(f.subscription()).toEqual(before);
    expect(purchaserGrants()).toBe(true);
    expect(f.applied).toEqual([]);
  });

  test("a DID_RENEW for a family-shared transaction cannot extend the purchaser's row", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() + HOUR) });
    await receiveAppleNotification(notification({
      type: "DID_RENEW", status: 1, signedDate: NOW.getTime(),
      tx: familyTransaction({ purchaseDate: NOW.getTime(), expiresDate: NOW.getTime() + 60 * DAY }, f.token),
    }), f.deps());
    expect(f.subscription().expiresAt?.getTime()).toBe(NOW.getTime() + HOUR);
    expect(f.subscription().lastTransactionId).toBe("period-1");
  });

  test("the history backfill applies the same rule", async () => {
    const shared = notification({
      type: "SUBSCRIBED", subtype: "INITIAL_BUY", status: 1, signedDate: NOW.getTime() - HOUR,
      tx: familyTransaction({ originalTransactionId: "family-original" }, f.tokenB),
    });
    f.serverApi = {
      subscriptionStatus: async () => null,
      notificationHistory: async (request) => ({
        signedPayloads: request.environment === "Production" && request.bundleId === "com.cmux.app" ? [shared] : [],
        hasMore: false,
        paginationToken: null,
      }),
    };
    const result = await backfillAppleNotifications(f.deps());
    expect(result.sources.find((source) => source.environment === "Production" && source.bundleId === "com.cmux.app")?.notifications)
      .toMatchObject({ skipped: 1, processed: 0 });
    expect([...f.store.notifications.values()].map((row) => row.error)).toEqual(["skipped: family_shared"]);
    expect(f.store.subscriptions.size).toBe(0);
  });
});

describe("renewal re-check", () => {
  test("Apple state that is family-shared is never written", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() + 2 * HOUR) });
    f.serverApi = f.statusApi(async () => ({
      status: 1,
      signedTransactionInfo: signer.sign(familyTransaction({
        purchaseDate: NOW.getTime() + 2 * HOUR, expiresDate: NOW.getTime() + 32 * DAY,
      }, f.token)),
      signedRenewalInfo: signer.sign(renewal({ signedDate: NOW.getTime() })),
    }));
    await retryAppleNotifications({}, f.deps());
    expect(f.statusCalls).toEqual([ORIGINAL]);
    expect(f.subscription().lastTransactionId).toBe("period-1");
    expect(f.subscription().expiresAt?.getTime()).toBe(NOW.getTime() + 2 * HOUR);
    expect(f.applied).toEqual([]);
  });
});
