import { beforeEach, describe, expect, test } from "bun:test";

import type { ServerEventInput } from "../services/analytics/serverEvents";
import { appleEnvironmentGrantsEntitlement } from "../services/billing/apple/config";
import { appleSubscriptionGrantsAccess, bestAppleEntitlement } from "../services/billing/apple/entitlement";
import type { AppleServerApi } from "../services/billing/apple/serverApi";
import {
  AppleTransactionRejectedError,
  processAppleNotification,
  receiveAppleNotification,
  recordClientAppleTransaction,
  retryAppleNotifications,
  type AppleIapDependencies,
} from "../services/billing/apple/service";
import { appleRevenueEstimate } from "../services/billing/apple/state";
import { AppleVerificationError, createAppleSignedDataVerifier } from "../services/billing/apple/verifier";
import { memoryAppleStore, type MemoryAppleStore } from "./helpers/apple-memory-store";
import { createAppleTestSigner } from "./helpers/apple-signing";

const BUNDLE = "com.cmux.app";
const ORIGINAL = "2000000000000100";
const DAY = 24 * 60 * 60 * 1000;
const NOW = new Date(Date.UTC(2026, 9, 15));
const env = { APPLE_IAP_BUNDLE_IDS: `${BUNDLE},dev.cmux.app.beta`, APPLE_IAP_APP_APPLE_ID: "6783338052" };
const signer = createAppleTestSigner();
const verifier = createAppleSignedDataVerifier({ rootCertificates: [signer.rootCertificate], onlineChecks: false, env });

let store: MemoryAppleStore;
let applied: string[];
let events: ServerEventInput[];
let applyFailures: number;
let serverApi: AppleServerApi | null;
let token: string;
let tokenB: string;

function deps(): AppleIapDependencies {
  return {
    store,
    verifier,
    serverApi,
    applyEntitlement: async (userId) => {
      if (applyFailures > 0) {
        applyFailures -= 1;
        throw new Error("Stack unavailable");
      }
      applied.push(userId);
    },
    captureEvent: async (input) => {
      events.push(input);
    },
    now: () => NOW,
  };
}

let transactionCounter = 0;
function transaction(overrides: Record<string, unknown> = {}) {
  transactionCounter += 1;
  return {
    transactionId: `30000000000${String(transactionCounter).padStart(5, "0")}`,
    originalTransactionId: ORIGINAL,
    bundleId: BUNDLE,
    productId: `${BUNDLE}.pro.monthly`,
    type: "Auto-Renewable Subscription",
    environment: "Production",
    appAccountToken: token,
    purchaseDate: NOW.getTime() - DAY,
    originalPurchaseDate: NOW.getTime() - DAY,
    expiresDate: NOW.getTime() + 29 * DAY,
    transactionReason: "PURCHASE",
    storefront: "USA",
    currency: "USD",
    price: 74990,
    signedDate: NOW.getTime() - DAY,
    ...overrides,
  };
}

function renewal(overrides: Record<string, unknown> = {}) {
  return {
    originalTransactionId: ORIGINAL,
    productId: `${BUNDLE}.pro.monthly`,
    autoRenewProductId: `${BUNDLE}.pro.monthly`,
    autoRenewStatus: 1,
    environment: "Production",
    signedDate: NOW.getTime() - DAY,
    ...overrides,
  };
}

let notificationCounter = 0;
function notification(input: {
  type: string;
  subtype?: string;
  status?: number;
  signedDate?: number;
  tx?: Record<string, unknown>;
  renewalInfo?: Record<string, unknown>;
  uuid?: string;
}) {
  notificationCounter += 1;
  const signedDate = input.signedDate ?? NOW.getTime() - DAY + notificationCounter * 1000;
  return signer.sign({
    notificationType: input.type,
    ...(input.subtype ? { subtype: input.subtype } : {}),
    notificationUUID: input.uuid ?? `00000000-0000-4000-8000-${String(notificationCounter).padStart(12, "0")}`,
    version: "2.0",
    signedDate,
    data: {
      bundleId: BUNDLE,
      environment: "Production",
      appAppleId: 6783338052,
      ...(input.status ? { status: input.status } : {}),
      signedTransactionInfo: signer.sign(transaction({ signedDate, ...input.tx })),
      signedRenewalInfo: signer.sign(renewal({ signedDate, ...input.renewalInfo })),
    },
  });
}

function subscription() {
  return store.subscriptions.get(ORIGINAL)!;
}

function grants(at: Date = NOW, environment: Record<string, string | undefined> = {}) {
  return appleSubscriptionGrantsAccess(subscription(), at, environment);
}

function eventNames() {
  return events.map((event) => event.event);
}

beforeEach(async () => {
  store = memoryAppleStore();
  applied = [];
  events = [];
  applyFailures = 0;
  serverApi = null;
  token = await store.accountTokenForUser("user-a");
  tokenB = await store.accountTokenForUser("user-b");
});

async function subscribe() {
  expect(await receiveAppleNotification(notification({ type: "SUBSCRIBED", subtype: "INITIAL_BUY", status: 1 }), deps()))
    .toBe("processed");
}

describe("client transactions", () => {
  test("records a verified purchase for the token's owner and applies the plan", async () => {
    const result = await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: signer.sign(transaction()) }, deps());
    expect(result).toEqual({ planId: "pro", status: "active", expiresAt: new Date(NOW.getTime() + 29 * DAY).toISOString() });
    expect(subscription()).toMatchObject({ userId: "user-a", planId: "pro", bundleId: BUNDLE, priceMilliunits: 74990 });
    expect(applied).toEqual(["user-a"]);
    expect(store.transactions.size).toBe(1);
  });

  test("is idempotent", async () => {
    const jws = signer.sign(transaction());
    await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: jws }, deps());
    await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: jws }, deps());
    expect(store.subscriptions.size).toBe(1);
    expect(store.transactions.size).toBe(1);
  });

  test("rejects a token that belongs to another user or was never minted", async () => {
    for (const appAccountToken of [token, "8f14e45f-ceea-467a-9575-1f2f3c4d5e6f"]) {
      const promise = recordClientAppleTransaction(
        { userId: "user-b", signedTransactionInfo: signer.sign(transaction({ appAccountToken })) },
        deps(),
      );
      await expect(promise).rejects.toMatchObject({ reason: "account_mismatch" });
    }
    expect(store.subscriptions.size).toBe(0);
    expect(applied).toEqual([]);
  });

  test("a token-less transaction cannot move a subscription another user owns", async () => {
    await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: signer.sign(transaction()) }, deps());
    const promise = recordClientAppleTransaction(
      { userId: "user-b", signedTransactionInfo: signer.sign(transaction({ appAccountToken: undefined })) },
      deps(),
    );
    await expect(promise).rejects.toBeInstanceOf(AppleTransactionRejectedError);
    expect(subscription().userId).toBe("user-a");
  });

  test("rejects non-subscriptions, unknown products and forged signatures", async () => {
    const consumable = signer.sign(transaction({ type: "Consumable" }));
    await expect(recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: consumable }, deps()))
      .rejects.toMatchObject({ reason: "not_subscription" });
    const unknown = signer.sign(transaction({ productId: `${BUNDLE}.ultra.monthly` }));
    await expect(recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: unknown }, deps()))
      .rejects.toMatchObject({ reason: "unknown_product" });
    const forged = createAppleTestSigner("Forger").sign(transaction());
    await expect(recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: forged }, deps()))
      .rejects.toBeInstanceOf(AppleVerificationError);
  });

  test("prefers Apple's current signed state from the Server API", async () => {
    serverApi = {
      subscriptionStatus: async () => ({
        status: 4,
        signedTransactionInfo: signer.sign(transaction({ signedDate: NOW.getTime() })),
        signedRenewalInfo: signer.sign(renewal({ signedDate: NOW.getTime(), isInBillingRetryPeriod: true, gracePeriodExpiresDate: NOW.getTime() + 3 * DAY })),
      }),
    };
    const result = await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: signer.sign(transaction()) }, deps());
    expect(result.status).toBe("grace_period");
    expect(subscription().gracePeriodExpiresAt?.getTime()).toBe(NOW.getTime() + 3 * DAY);
  });

  test("falls back to the client transaction when the Server API fails", async () => {
    serverApi = { subscriptionStatus: async () => { throw new Error("503"); } };
    const result = await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: signer.sign(transaction()) }, deps());
    expect(result.status).toBe("active");
  });
});

describe("App Store Server Notifications", () => {
  test("SUBSCRIBED INITIAL_BUY starts a granting subscription and emits subscription_started", async () => {
    await subscribe();
    expect(subscription()).toMatchObject({ status: "active", planId: "pro", userId: "user-a", autoRenewEnabled: true });
    expect(grants()).toBe(true);
    expect(applied).toEqual(["user-a"]);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      event: "subscription_started",
      distinctId: "user-a",
      properties: {
        source: "apple", plan_id: "pro", product_id: `${BUNDLE}.pro.monthly`, storefront: "USA", currency: "USD",
        price: 74.99, price_usd_estimate: 74.99, net_usd_estimate: 52.49, environment: "Production",
        original_transaction_id: ORIGINAL,
      },
    });
  });

  test("SUBSCRIBED RESUBSCRIBE reactivates and emits subscription_resubscribed", async () => {
    await receiveAppleNotification(notification({ type: "EXPIRED", subtype: "VOLUNTARY", status: 2, tx: { expiresDate: NOW.getTime() - DAY } }), deps());
    await receiveAppleNotification(notification({ type: "SUBSCRIBED", subtype: "RESUBSCRIBE", status: 1 }), deps());
    expect(subscription().status).toBe("active");
    expect(eventNames()).toEqual(["subscription_expired", "subscription_resubscribed"]);
  });

  test("DID_RENEW extends expiry, records the renewal transaction, and emits subscription_renewed", async () => {
    await subscribe();
    const nextExpiry = NOW.getTime() + 59 * DAY;
    await receiveAppleNotification(notification({ type: "DID_RENEW", status: 1, tx: { expiresDate: nextExpiry, transactionReason: "RENEWAL" } }), deps());
    expect(subscription().expiresAt?.getTime()).toBe(nextExpiry);
    expect([...store.transactions.values()].map((row) => row.type)).toEqual(["PURCHASE", "RENEWAL"]);
    expect(eventNames()).toEqual(["subscription_started", "subscription_renewed"]);
  });

  test("DID_CHANGE_RENEWAL_PREF UPGRADE moves to Max now; DOWNGRADE keeps the current plan until renewal", async () => {
    await subscribe();
    await receiveAppleNotification(notification({
      type: "DID_CHANGE_RENEWAL_PREF", subtype: "UPGRADE", status: 1,
      tx: { productId: `${BUNDLE}.max.monthly` }, renewalInfo: { autoRenewProductId: `${BUNDLE}.max.monthly` },
    }), deps());
    expect(subscription().planId).toBe("max");
    await receiveAppleNotification(notification({
      type: "DID_CHANGE_RENEWAL_PREF", subtype: "DOWNGRADE", status: 1,
      tx: { productId: `${BUNDLE}.max.monthly` }, renewalInfo: { autoRenewProductId: `${BUNDLE}.go.monthly` },
    }), deps());
    expect(subscription()).toMatchObject({ planId: "max", autoRenewProductId: `${BUNDLE}.go.monthly` });
    expect(eventNames()).toEqual(["subscription_started", "subscription_plan_changed", "subscription_plan_changed"]);
  });

  test("DID_CHANGE_RENEWAL_STATUS AUTO_RENEW_DISABLED keeps access and emits subscription_cancel_scheduled", async () => {
    await subscribe();
    await receiveAppleNotification(notification({
      type: "DID_CHANGE_RENEWAL_STATUS", subtype: "AUTO_RENEW_DISABLED", status: 1, renewalInfo: { autoRenewStatus: 0 },
    }), deps());
    expect(subscription().autoRenewEnabled).toBe(false);
    expect(grants()).toBe(true);
    await receiveAppleNotification(notification({
      type: "DID_CHANGE_RENEWAL_STATUS", subtype: "AUTO_RENEW_ENABLED", status: 1, renewalInfo: { autoRenewStatus: 1 },
    }), deps());
    expect(subscription().autoRenewEnabled).toBe(true);
    expect(eventNames()).toEqual(["subscription_started", "subscription_cancel_scheduled"]);
  });

  test("DID_FAIL_TO_RENEW GRACE_PERIOD grants until the grace period ends", async () => {
    await subscribe();
    const graceEnd = NOW.getTime() + 6 * DAY;
    await receiveAppleNotification(notification({
      type: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD", status: 4,
      tx: { expiresDate: NOW.getTime() - DAY },
      renewalInfo: { isInBillingRetryPeriod: true, gracePeriodExpiresDate: graceEnd },
    }), deps());
    expect(subscription().status).toBe("grace_period");
    expect(grants()).toBe(true);
    expect(grants(new Date(graceEnd + 1))).toBe(false);
    expect(eventNames()).toEqual(["subscription_started", "subscription_grace_period_entered"]);
  });

  test("DID_FAIL_TO_RENEW without grace is billing retry without access, and GRACE_PERIOD_EXPIRED ends access", async () => {
    await subscribe();
    await receiveAppleNotification(notification({
      type: "DID_FAIL_TO_RENEW", status: 3, tx: { expiresDate: NOW.getTime() - DAY }, renewalInfo: { isInBillingRetryPeriod: true },
    }), deps());
    expect(subscription().status).toBe("billing_retry");
    expect(grants()).toBe(false);
    await receiveAppleNotification(notification({
      type: "GRACE_PERIOD_EXPIRED", status: 3, tx: { expiresDate: NOW.getTime() - DAY },
      renewalInfo: { isInBillingRetryPeriod: true, gracePeriodExpiresDate: NOW.getTime() - 1 },
    }), deps());
    expect(subscription().status).toBe("billing_retry");
    expect(grants()).toBe(false);
    expect(eventNames()).toEqual(["subscription_started", "subscription_billing_issue"]);
  });

  test("EXPIRED removes the grant and emits subscription_expired", async () => {
    await subscribe();
    await receiveAppleNotification(notification({ type: "EXPIRED", subtype: "VOLUNTARY", status: 2, tx: { expiresDate: NOW.getTime() - DAY } }), deps());
    expect(subscription().status).toBe("expired");
    expect(grants()).toBe(false);
    expect(applied).toEqual(["user-a", "user-a"]);
    expect(eventNames()).toEqual(["subscription_started", "subscription_expired"]);
  });

  test("REFUND revokes, REFUND_REVERSED restores", async () => {
    await subscribe();
    await receiveAppleNotification(notification({
      type: "REFUND", status: 5, tx: { transactionId: "refunded-1", revocationDate: NOW.getTime(), revocationReason: 0 },
    }), deps());
    expect(subscription()).toMatchObject({ status: "revoked", revocationReason: 0 });
    expect(subscription().revokedAt).not.toBeNull();
    expect(grants()).toBe(false);
    expect(store.transactions.get("refunded-1")?.revokedAt).not.toBeNull();
    await receiveAppleNotification(notification({ type: "REFUND_REVERSED", status: 1, tx: { transactionId: "refunded-1" } }), deps());
    expect(subscription().status).toBe("active");
    expect(store.transactions.get("refunded-1")?.revokedAt).toBeNull();
    expect(eventNames()).toEqual(["subscription_started", "subscription_refunded"]);
  });

  test("REVOKE (Family Sharing) removes the grant and emits subscription_revoked", async () => {
    await subscribe();
    await receiveAppleNotification(notification({ type: "REVOKE", status: 5, tx: { revocationDate: NOW.getTime() } }), deps());
    expect(grants()).toBe(false);
    expect(eventNames()).toEqual(["subscription_started", "subscription_revoked"]);
  });

  test("PRICE_INCREASE and RENEWAL_EXTENDED update state without a lifecycle event", async () => {
    await subscribe();
    await receiveAppleNotification(notification({ type: "PRICE_INCREASE", subtype: "PENDING", status: 1 }), deps());
    const extended = NOW.getTime() + 40 * DAY;
    await receiveAppleNotification(notification({ type: "RENEWAL_EXTENDED", status: 1, tx: { expiresDate: extended } }), deps());
    expect(subscription().expiresAt?.getTime()).toBe(extended);
    expect(eventNames()).toEqual(["subscription_started"]);
  });

  test("CONSUMPTION_REQUEST and TEST are recorded and closed without state", async () => {
    expect(await receiveAppleNotification(notification({ type: "CONSUMPTION_REQUEST", status: 1 }), deps())).toBe("skipped");
    const test = signer.sign({
      notificationType: "TEST", notificationUUID: "00000000-0000-4000-8000-0000000000aa", version: "2.0",
      signedDate: NOW.getTime(), data: { bundleId: BUNDLE, environment: "Production", appAppleId: 6783338052 },
    });
    expect(await receiveAppleNotification(test, deps())).toBe("skipped");
    expect(store.notifications.size).toBe(2);
    expect([...store.notifications.values()].every((row) => row.processedAt !== null)).toBe(true);
    expect(store.subscriptions.size).toBe(0);
    expect(events).toEqual([]);
  });

  test("a redelivered notification is a no-op", async () => {
    const payload = notification({ type: "SUBSCRIBED", subtype: "INITIAL_BUY", status: 1 });
    expect(await receiveAppleNotification(payload, deps())).toBe("processed");
    expect(await receiveAppleNotification(payload, deps())).toBe("duplicate");
    expect(applied).toEqual(["user-a"]);
    expect(events).toHaveLength(1);
  });

  test("an older notification never overwrites newer state", async () => {
    await subscribe();
    const late = NOW.getTime();
    await receiveAppleNotification(notification({ type: "EXPIRED", status: 2, signedDate: late, tx: { expiresDate: late - DAY } }), deps());
    await receiveAppleNotification(notification({
      type: "DID_RENEW", status: 1, signedDate: late - 60_000, tx: { transactionId: "late-renewal", expiresDate: late + 29 * DAY },
    }), deps());
    expect(subscription().status).toBe("expired");
    expect(subscription().stateSignedAt.getTime()).toBe(late);
    // The older fact is still in the transaction ledger and analytics.
    expect(store.transactions.has("late-renewal")).toBe(true);
    expect(eventNames()).toEqual(["subscription_started", "subscription_expired", "subscription_renewed"]);
  });

  test("a failed entitlement keeps the ledger row pending and the retry job finishes it once", async () => {
    applyFailures = 1;
    expect(await receiveAppleNotification(notification({ type: "SUBSCRIBED", subtype: "INITIAL_BUY", status: 1 }), deps())).toBe("failed");
    const [row] = [...store.notifications.values()];
    expect(row).toMatchObject({ processedAt: null });
    expect(row!.error).toContain("Stack unavailable");
    expect(events).toEqual([]);

    const result = await retryAppleNotifications({}, deps());
    expect(result.notifications.processed).toBe(1);
    expect(store.notifications.get(row!.notificationUuid)?.processedAt).not.toBeNull();
    expect(eventNames()).toEqual(["subscription_started"]);
    expect((await retryAppleNotifications({}, deps())).notifications.processed).toBe(0);
  });

  test("a notification for an unlinked purchase is closed, not retried forever", async () => {
    expect(await receiveAppleNotification(notification({ type: "SUBSCRIBED", subtype: "INITIAL_BUY", status: 1, tx: { appAccountToken: undefined } }), deps()))
      .toBe("skipped");
    expect([...store.notifications.values()][0]?.error).toBe("skipped: unlinked_account");
    expect(await store.pendingNotifications(10)).toEqual([]);
  });

  test("the retry job re-derives the plan for users whose subscription expired without a notification", async () => {
    await subscribe();
    store.subscriptions.set(ORIGINAL, { ...subscription(), expiresAt: new Date(NOW.getTime() - 60_000) });
    applied = [];
    const result = await retryAppleNotifications({}, deps());
    expect(result.lapsedUsers).toBe(1);
    expect(applied).toEqual(["user-a"]);
    expect(grants()).toBe(false);
  });

  test("rejects an unsigned or forged notification before writing the ledger", async () => {
    await expect(receiveAppleNotification("garbage", deps())).rejects.toBeInstanceOf(AppleVerificationError);
    const forged = createAppleTestSigner("Forger").sign({
      notificationType: "SUBSCRIBED", notificationUUID: "x", signedDate: NOW.getTime(),
      data: { bundleId: BUNDLE, environment: "Production", appAppleId: 6783338052 },
    });
    await expect(receiveAppleNotification(forged, deps())).rejects.toBeInstanceOf(AppleVerificationError);
    expect(store.notifications.size).toBe(0);
  });

  test("processAppleNotification reports a storage failure as failed", async () => {
    await subscribe();
    const [row] = [...store.notifications.values()];
    const broken = { ...deps(), store: { ...store, writeSubscriptionState: async () => { throw new Error("db down"); } } };
    expect(await processAppleNotification({ ...row!, processedAt: null }, broken)).toBe("failed");
  });
});

describe("subscription ownership", () => {
  // The same Apple ID signs into cmux account B and buys again (upgrade or
  // resubscribe). The newest transaction carries B's appAccountToken, which
  // is authoritative: the subscription moves to B and A falls back.
  function upgradeForB(overrides: Record<string, unknown> = {}) {
    return transaction({
      appAccountToken: tokenB,
      productId: `${BUNDLE}.max.monthly`,
      purchaseDate: NOW.getTime(),
      signedDate: NOW.getTime(),
      expiresDate: NOW.getTime() + 30 * DAY,
      ...overrides,
    });
  }

  test("a newer client-posted purchase with another user's token moves the subscription to that user", async () => {
    await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: signer.sign(transaction()) }, deps());
    applied = [];
    const result = await recordClientAppleTransaction(
      { userId: "user-b", signedTransactionInfo: signer.sign(upgradeForB()) },
      deps(),
    );
    expect(result.planId).toBe("max");
    expect(subscription()).toMatchObject({ userId: "user-b", appAccountToken: tokenB, planId: "max" });
    expect([...applied].sort()).toEqual(["user-a", "user-b"]);
  });

  test("a newer notified purchase with another user's token moves the subscription to that user", async () => {
    await subscribe();
    applied = [];
    expect(await receiveAppleNotification(notification({
      type: "DID_CHANGE_RENEWAL_PREF", subtype: "UPGRADE", status: 1,
      tx: { appAccountToken: tokenB, productId: `${BUNDLE}.max.monthly`, purchaseDate: NOW.getTime() },
      renewalInfo: { autoRenewProductId: `${BUNDLE}.max.monthly` },
    }), deps())).toBe("processed");
    expect(subscription()).toMatchObject({ userId: "user-b", appAccountToken: tokenB, planId: "max" });
    expect([...applied].sort()).toEqual(["user-a", "user-b"]);
    expect(events.at(-1)).toMatchObject({ event: "subscription_plan_changed", distinctId: "user-b" });
  });

  test("an older transaction with another user's token cannot take the subscription", async () => {
    await recordClientAppleTransaction({
      userId: "user-a",
      signedTransactionInfo: signer.sign(transaction({ purchaseDate: NOW.getTime(), signedDate: NOW.getTime() - DAY })),
    }, deps());
    const older = upgradeForB({ purchaseDate: NOW.getTime() - 2 * DAY, signedDate: NOW.getTime() });
    await expect(recordClientAppleTransaction({ userId: "user-b", signedTransactionInfo: signer.sign(older) }, deps()))
      .rejects.toMatchObject({ reason: "account_mismatch" });
    expect(subscription().userId).toBe("user-a");
  });

  test("a late notification about the previous owner's transaction does not move it back", async () => {
    await subscribe();
    await receiveAppleNotification(notification({
      type: "SUBSCRIBED", subtype: "RESUBSCRIBE", status: 1, signedDate: NOW.getTime(),
      tx: { appAccountToken: tokenB, purchaseDate: NOW.getTime() },
    }), deps());
    expect(await receiveAppleNotification(notification({
      type: "DID_CHANGE_RENEWAL_STATUS", subtype: "AUTO_RENEW_DISABLED", status: 1, signedDate: NOW.getTime() - 60_000,
      renewalInfo: { autoRenewStatus: 0 },
    }), deps())).toBe("processed");
    expect(subscription().userId).toBe("user-b");
  });

  test("the caller still cannot post another user's token (replay guard)", async () => {
    await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: signer.sign(transaction()) }, deps());
    await expect(recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: signer.sign(upgradeForB()) }, deps()))
      .rejects.toMatchObject({ reason: "account_mismatch" });
    expect(subscription().userId).toBe("user-a");
  });
});

describe("Apple entitlement policy", () => {
  const row = {
    originalTransactionId: "1", planId: "pro", status: "active", environment: "Sandbox", bundleId: BUNDLE,
    expiresAt: new Date(NOW.getTime() + DAY), gracePeriodExpiresAt: null,
  };

  test("production grants Sandbox purchases only for the App Store bundle (App Review)", () => {
    const production = { VERCEL_ENV: "production" };
    expect(appleEnvironmentGrantsEntitlement({ environment: "Sandbox", bundleId: BUNDLE }, production)).toBe(true);
    expect(appleEnvironmentGrantsEntitlement({ environment: "Sandbox", bundleId: "dev.cmux.app.beta" }, production)).toBe(false);
    expect(appleEnvironmentGrantsEntitlement({ environment: "Sandbox", bundleId: BUNDLE }, { ...production, APPLE_IAP_SANDBOX_ENTITLEMENTS: "none" })).toBe(false);
    expect(appleEnvironmentGrantsEntitlement({ environment: "Sandbox", bundleId: "dev.cmux.app.beta" }, {})).toBe(true);
    expect(appleEnvironmentGrantsEntitlement({ environment: "Xcode", bundleId: BUNDLE }, {})).toBe(false);
  });

  test("the highest granting plan wins and unknown plans never grant", () => {
    const best = bestAppleEntitlement([
      row,
      { ...row, originalTransactionId: "2", planId: "max" },
      { ...row, originalTransactionId: "3", planId: "team" },
      { ...row, originalTransactionId: "4", planId: "max", status: "expired" },
    ], NOW, {});
    expect(best?.originalTransactionId).toBe("2");
  });

  test("an active row past its expiry does not grant", () => {
    expect(appleSubscriptionGrantsAccess({ ...row, expiresAt: new Date(NOW.getTime() - 1) }, NOW, {})).toBe(false);
  });
});

describe("Apple revenue estimates", () => {
  test("uses the USD price, then the US list price, and 15% after a year of service", () => {
    const first = appleRevenueEstimate({ planId: "pro", currency: "USD", priceMilliunits: 74990, purchaseDate: NOW, originalPurchaseDate: NOW });
    expect(first).toMatchObject({ price: 74.99, priceUsd: 74.99, netUsd: 52.49, commission: 0.3 });
    const euro = appleRevenueEstimate({
      planId: "max", currency: "EUR", priceMilliunits: 299990, purchaseDate: NOW, originalPurchaseDate: new Date(NOW.getTime() - 400 * DAY),
    });
    expect(euro).toMatchObject({ price: 299.99, priceUsd: 299.99, netUsd: 254.99, commission: 0.15 });
  });
});
