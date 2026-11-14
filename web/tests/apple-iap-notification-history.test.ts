// Lost App Store Server Notifications are backfilled from Apple's Get
// Notification History and applied through the webhook's own verify, ledger
// and apply path, idempotent on notificationUUID, with a durable cursor.

import { beforeEach, describe, expect, test } from "bun:test";

import { appleNotificationHistorySources } from "../services/billing/apple/config";
import { APPLE_HISTORY_OVERLAP_MS, APPLE_HISTORY_RETENTION_MS, backfillAppleNotifications } from "../services/billing/apple/history";
import { AppleHistoryPaginationError, type AppleServerApi } from "../services/billing/apple/serverApi";
import { receiveAppleNotification } from "../services/billing/apple/service";
import { AppleVerificationError } from "../services/billing/apple/verifier";
import {
  BUNDLE,
  DAY,
  HOUR,
  NOW,
  ORIGINAL,
  createFixture,
  forger,
  notification,
  seedSubscription,
  transaction,
  type Fixture,
} from "./helpers/apple-iap-fixture";

type HistoryRequest = Parameters<AppleServerApi["notificationHistory"]>[0];

let f: Fixture;
let requests: HistoryRequest[];

beforeEach(async () => {
  f = await createFixture();
  requests = [];
});

/** A Server API whose history for the App Store app's Production environment is `pages`. */
function historyApi(
  pages: readonly { signedPayloads: string[]; hasMore?: boolean; paginationToken?: string | null }[] | ((request: HistoryRequest) => never),
): AppleServerApi {
  return {
    subscriptionStatus: async () => null,
    notificationHistory: async (request) => {
      requests.push(request);
      if (typeof pages === "function") return pages(request);
      if (request.bundleId !== BUNDLE || request.environment !== "Production") {
        return { signedPayloads: [], hasMore: false, paginationToken: null };
      }
      const index = request.paginationToken ? Number(request.paginationToken.replace("page-", "")) : 0;
      const page = pages[index]!;
      return { signedPayloads: page.signedPayloads, hasMore: page.hasMore ?? false, paginationToken: page.paginationToken ?? null };
    },
  };
}

function productionRequests(): HistoryRequest[] {
  return requests.filter((request) => request.bundleId === BUNDLE && request.environment === "Production");
}

const oldExpiry = NOW.getTime() - 3 * HOUR;
function missedRenewal(uuid = "00000000-0000-4000-a000-000000000001") {
  return notification({
    type: "DID_RENEW",
    status: 1,
    uuid,
    signedDate: oldExpiry,
    tx: transaction({ transactionId: "period-2", purchaseDate: oldExpiry, expiresDate: oldExpiry + 30 * DAY, transactionReason: "RENEWAL" }, f.token),
  });
}

describe("history sources", () => {
  test("production backfills Production for every bundle and Sandbox only for the App Store app", () => {
    expect(appleNotificationHistorySources({ VERCEL_ENV: "production" })).toEqual([
      { bundleId: "com.cmux.app", environment: "Production" },
      { bundleId: "com.cmux.app", environment: "Sandbox" },
      { bundleId: "dev.cmux.app.beta", environment: "Production" },
    ]);
  });

  test("other deployments also backfill the beta's Sandbox, and the override wins", () => {
    expect(appleNotificationHistorySources({ VERCEL_ENV: "preview" })).toHaveLength(4);
    expect(appleNotificationHistorySources({ VERCEL_ENV: "production", APPLE_IAP_SANDBOX_ENTITLEMENTS: "none" }))
      .toEqual([
        { bundleId: "com.cmux.app", environment: "Production" },
        { bundleId: "dev.cmux.app.beta", environment: "Production" },
      ]);
  });
});

describe("backfill", () => {
  test("applies a DID_RENEW Apple never delivered, then treats it as a duplicate", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry) });
    f.serverApi = historyApi([{ signedPayloads: [missedRenewal()] }]);

    const first = await backfillAppleNotifications(f.deps());
    expect(first.configured).toBe(true);
    expect(first.failures).toBe(0);
    expect(first.sources.find((source) => source.environment === "Production" && source.bundleId === BUNDLE))
      .toMatchObject({ complete: true, notifications: { processed: 1 } });
    expect(f.subscription()).toMatchObject({ lastTransactionId: "period-2", status: "active" });
    expect(f.subscription().expiresAt?.getTime()).toBe(oldExpiry + 30 * DAY);
    expect(f.applied).toEqual(["user-a"]);

    const second = await backfillAppleNotifications(f.deps());
    expect(second.sources.find((source) => source.environment === "Production" && source.bundleId === BUNDLE)?.notifications)
      .toMatchObject({ processed: 0, duplicate: 1 });
    expect(f.store.notifications.size).toBe(1);
  });

  test("the first window covers Apple's whole retention, then each window starts at the cursor minus the overlap", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry) });
    // A notification already in the ledger does not narrow the first window:
    // anything Apple gave up on before it is what the backfill is for.
    await receiveAppleNotification(notification({
      type: "DID_CHANGE_RENEWAL_PREF", status: 1, signedDate: NOW.getTime() - 2 * DAY, tx: transaction({ transactionId: "period-1" }, f.token),
    }), f.deps());
    f.serverApi = historyApi([{ signedPayloads: [] }]);

    await backfillAppleNotifications(f.deps());
    expect(productionRequests()[0]).toMatchObject({ paginationToken: null });
    expect(productionRequests()[0]!.startDate.getTime()).toBe(NOW.getTime() - APPLE_HISTORY_RETENTION_MS);
    expect(productionRequests()[0]!.endDate.getTime()).toBe(NOW.getTime());
    expect(f.store.historyCursors.get(`Production:${BUNDLE}`)).toMatchObject({ paginationToken: null });
    expect(f.store.historyCursors.get(`Production:${BUNDLE}`)?.nextStartAt.getTime()).toBe(NOW.getTime());

    requests = [];
    f.clock = new Date(NOW.getTime() + HOUR / 2);
    await backfillAppleNotifications(f.deps());
    expect(productionRequests()[0]!.startDate.getTime()).toBe(NOW.getTime() - APPLE_HISTORY_OVERLAP_MS);
  });

  test("never asks for more than Apple's 180 days", () => {
    expect(APPLE_HISTORY_RETENTION_MS).toBeLessThan(180 * DAY);
  });

  test("a retryable verification failure keeps the cursor so the page is read again", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry) });
    f.serverApi = historyApi([{ signedPayloads: [missedRenewal()] }]);
    const outage = {
      ...f.deps().verifier,
      verifyNotification: async () => { throw new AppleVerificationError("retryable"); },
    };
    const result = await backfillAppleNotifications(f.deps({ verifier: outage }));
    expect(result.sources.find((source) => source.environment === "Production" && source.bundleId === BUNDLE))
      .toMatchObject({ complete: false, notifications: { rejected: 0 } });
    expect(f.store.historyCursors.get(`Production:${BUNDLE}`)).toBeUndefined();

    await backfillAppleNotifications(f.deps());
    expect(f.subscription().lastTransactionId).toBe("period-2");
  });

  test("a notification already in the ledger is left to the retry job and its backoff", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry) });
    const payload = missedRenewal();
    f.applyFailures = 1;
    expect(await receiveAppleNotification(payload, f.deps())).toBe("failed");
    const [row] = [...f.store.notifications.values()];
    expect(row!.attemptCount).toBe(1);
    f.serverApi = historyApi([{ signedPayloads: [payload] }]);
    const result = await backfillAppleNotifications(f.deps());
    expect(result.sources.find((source) => source.environment === "Production" && source.bundleId === BUNDLE)?.notifications)
      .toMatchObject({ duplicate: 1, processed: 0, failed: 0 });
    expect(f.store.notifications.get(row!.notificationUuid)).toMatchObject({ attemptCount: 1, processedAt: null });
  });

  test("stops requesting pages once the cron's time budget is spent", async () => {
    f.serverApi = historyApi([{ signedPayloads: [] }]);
    const result = await backfillAppleNotifications(f.deps(), { deadlineMs: Date.now() - 1 });
    expect(requests).toEqual([]);
    expect(result.failures).toBe(0);
    expect(result.sources.every((source) => !source.complete && source.pages === 0)).toBe(true);
  });

  test("paginates within the page budget and resumes the same window on the next run", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry) });
    f.serverApi = historyApi([
      { signedPayloads: [], hasMore: true, paginationToken: "page-1" },
      { signedPayloads: [missedRenewal()], hasMore: false },
    ]);
    const first = await backfillAppleNotifications(f.deps(), { pagesPerSource: 1 });
    expect(first.sources.find((source) => source.environment === "Production" && source.bundleId === BUNDLE))
      .toMatchObject({ complete: false, pages: 1 });
    const saved = f.store.historyCursors.get(`Production:${BUNDLE}`)!;
    expect(saved.paginationToken).toBe("page-1");
    expect(f.subscription().lastTransactionId).toBe("period-1");

    requests = [];
    f.clock = new Date(NOW.getTime() + HOUR / 2);
    await backfillAppleNotifications(f.deps(), { pagesPerSource: 1 });
    expect(productionRequests()[0]).toMatchObject({ paginationToken: "page-1" });
    expect(productionRequests()[0]!.startDate.getTime()).toBe(saved.windowStartAt!.getTime());
    expect(productionRequests()[0]!.endDate.getTime()).toBe(NOW.getTime());
    expect(f.subscription().lastTransactionId).toBe("period-2");
    expect(f.store.historyCursors.get(`Production:${BUNDLE}`)).toMatchObject({ paginationToken: null });
  });

  test("a window that started at the retention limit can still be resumed for a day", async () => {
    f.serverApi = historyApi([
      { signedPayloads: [], hasMore: true, paginationToken: "page-1" },
      { signedPayloads: [], hasMore: false },
    ]);
    await backfillAppleNotifications(f.deps(), { pagesPerSource: 1 });
    expect(productionRequests()[0]!.startDate.getTime()).toBe(NOW.getTime() - APPLE_HISTORY_RETENTION_MS);
    requests = [];
    f.clock = new Date(NOW.getTime() + 12 * HOUR);
    await backfillAppleNotifications(f.deps(), { pagesPerSource: 1 });
    expect(productionRequests()[0]).toMatchObject({ paginationToken: "page-1" });
    expect(f.store.historyCursors.get(`Production:${BUNDLE}`)).toMatchObject({ paginationToken: null });
  });

  test("a rejected pagination token restarts the window instead of failing forever", async () => {
    f.store.historyCursors.set(`Production:${BUNDLE}`, {
      bundleId: BUNDLE, environment: "Production", nextStartAt: new Date(NOW.getTime() - DAY),
      windowStartAt: new Date(NOW.getTime() - DAY), windowEndAt: new Date(NOW.getTime() - HOUR), paginationToken: "expired",
    });
    f.serverApi = historyApi((request) => {
      if (request.paginationToken) throw new AppleHistoryPaginationError("expired");
      throw new Error("unexpected");
    });
    const result = await backfillAppleNotifications(f.deps());
    expect(result.sources.find((source) => source.environment === "Production" && source.bundleId === BUNDLE))
      .toMatchObject({ complete: false, error: null });
    expect(f.store.historyCursors.get(`Production:${BUNDLE}`)).toMatchObject({ paginationToken: null, windowStartAt: null });
    expect(f.store.historyCursors.get(`Production:${BUNDLE}`)?.nextStartAt.getTime()).toBe(NOW.getTime() - DAY);
  });

  test("a payload that fails verification is counted and skipped; the cursor still moves", async () => {
    const forged = notification({
      type: "DID_RENEW", status: 1, signedDate: oldExpiry, signWith: forger, tx: transaction({ transactionId: "forged" }, f.token),
    });
    f.serverApi = historyApi([{ signedPayloads: [forged] }]);
    const result = await backfillAppleNotifications(f.deps());
    expect(result.failures).toBe(0);
    expect(result.sources.find((source) => source.environment === "Production" && source.bundleId === BUNDLE)?.notifications)
      .toMatchObject({ rejected: 1 });
    expect(f.store.notifications.size).toBe(0);
    expect(f.store.historyCursors.get(`Production:${BUNDLE}`)?.nextStartAt.getTime()).toBe(NOW.getTime());
  });

  test("a ledger write failure leaves the cursor where it was so the page is read again", async () => {
    f.serverApi = historyApi([{ signedPayloads: [missedRenewal()] }]);
    const broken = { ...f.store, insertNotification: async () => { throw new Error("db down"); } };
    const result = await backfillAppleNotifications(f.deps({ store: broken }));
    expect(result.failures).toBe(1);
    expect(f.store.historyCursors.get(`Production:${BUNDLE}`)).toBeUndefined();
  });

  test("a Server API error fails that history only", async () => {
    f.serverApi = historyApi((request) => {
      throw new Error(`Apple 500 for ${request.environment}`);
    });
    const result = await backfillAppleNotifications(f.deps());
    expect(result.failures).toBe(result.sources.length);
    expect(f.store.historyCursors.size).toBe(0);
  });

  test("does nothing without the App Store Server API key", async () => {
    expect(await backfillAppleNotifications(f.deps())).toEqual({ configured: false, sources: [], failures: 0 });
  });

  test("the backfilled renewal goes through the same ownership rules as the webhook", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry) });
    // A token cmux never minted cannot move or claim the subscription.
    const stranger = notification({
      type: "DID_RENEW", status: 1, signedDate: oldExpiry,
      tx: transaction({ transactionId: "period-2", purchaseDate: oldExpiry, expiresDate: oldExpiry + 30 * DAY }, "11111111-1111-4111-8111-111111111111"),
    });
    f.serverApi = historyApi([{ signedPayloads: [stranger] }]);
    await backfillAppleNotifications(f.deps());
    expect(f.subscription()).toMatchObject({ userId: "user-a", originalTransactionId: ORIGINAL });
  });
});
