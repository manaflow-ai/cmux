// One account paying for a personal plan through both Stripe and the App
// Store. Which App Store rows count, how incidents open and announce once,
// that payment-path reporting never throws, and the daily scan.

import { beforeEach, describe, expect, test } from "bun:test";

import type { ServerEventInput } from "../services/analytics/serverEvents";
import type { AppleEntitlementRow } from "../services/billing/apple/entitlement";
import {
  APPLE_BILLING_RETRY_WINDOW_MS,
  appleSubscriptionBlockingStripeCheckout,
  appleSubscriptionMayBill,
  detectDoubleBillingForUser,
  reportDoubleBillingForUser,
  scanDoubleBilling,
  type DoubleBillingDependencies,
  type DoubleBillingIncidentWrite,
  type DoubleBillingStore,
  type StripeRecurringSubscription,
} from "../services/billing/doubleBilling";

const DAY = 24 * 60 * 60 * 1000;
const NOW = new Date(Date.UTC(2026, 10, 13, 12));

function apple(overrides: Partial<AppleEntitlementRow> = {}): AppleEntitlementRow {
  return {
    originalTransactionId: "otx-1",
    planId: "pro",
    status: "active",
    environment: "Production",
    bundleId: "com.cmux.app",
    expiresAt: new Date(NOW.getTime() + 20 * DAY),
    gracePeriodExpiresAt: null,
    autoRenewEnabled: true,
    ...overrides,
  };
}

const stripeSub: StripeRecurringSubscription = { id: "sub_1", plan: "pro", status: "active" };

describe("appleSubscriptionMayBill", () => {
  test.each<[string, Partial<AppleEntitlementRow>, boolean]>([
    ["active in its paid period", {}, true],
    ["active in its paid period with auto-renew off (already paid)", { autoRenewEnabled: false }, true],
    ["active past expiry with auto-renew on (renewal pending)", { expiresAt: new Date(NOW.getTime() - DAY) }, true],
    ["active past expiry with auto-renew off", { expiresAt: new Date(NOW.getTime() - DAY), autoRenewEnabled: false }, false],
    ["grace period", { status: "grace_period", expiresAt: new Date(NOW.getTime() - DAY), gracePeriodExpiresAt: new Date(NOW.getTime() + 5 * DAY) }, true],
    ["billing retry past grace, auto-renew on (does not grant, can recover)", { status: "billing_retry", expiresAt: new Date(NOW.getTime() - 20 * DAY), gracePeriodExpiresAt: new Date(NOW.getTime() - 4 * DAY) }, true],
    ["billing retry with unknown auto-renew", { status: "billing_retry", expiresAt: new Date(NOW.getTime() - 20 * DAY), autoRenewEnabled: null }, true],
    ["billing retry with auto-renew off", { status: "billing_retry", expiresAt: new Date(NOW.getTime() - 20 * DAY), autoRenewEnabled: false }, false],
    ["billing retry just inside the 60-day window", { status: "billing_retry", expiresAt: new Date(NOW.getTime() - APPLE_BILLING_RETRY_WINDOW_MS + 1000) }, true],
    ["billing retry past the 60-day window (missed EXPIRED)", { status: "billing_retry", expiresAt: new Date(NOW.getTime() - APPLE_BILLING_RETRY_WINDOW_MS) }, false],
    ["expired", { status: "expired", expiresAt: new Date(NOW.getTime() - DAY) }, false],
    ["revoked", { status: "revoked" }, false],
    ["Sandbox (free)", { environment: "Sandbox" }, false],
    ["an unknown plan", { planId: "team" }, false],
    ["no expiry (malformed): refuse the side that could double charge", { expiresAt: null }, true],
  ])("%s", (_label, overrides, expected) => {
    expect(appleSubscriptionMayBill(apple(overrides), NOW)).toBe(expected);
  });
});

describe("appleSubscriptionBlockingStripeCheckout", () => {
  test("returns the first row that may bill, or null", async () => {
    const retry = apple({ originalTransactionId: "otx-retry", status: "billing_retry", expiresAt: new Date(NOW.getTime() - 10 * DAY) });
    expect(await appleSubscriptionBlockingStripeCheckout("u", { now: NOW, rows: async () => [apple({ status: "expired" }), retry] }))
      .toBe(retry);
    expect(await appleSubscriptionBlockingStripeCheckout("u", { now: NOW, rows: async () => [apple({ environment: "Sandbox" })] }))
      .toBeNull();
  });

  test("a read failure throws so checkout fails closed", async () => {
    await expect(appleSubscriptionBlockingStripeCheckout("u", { rows: async () => { throw new Error("db down"); } }))
      .rejects.toThrow("db down");
  });
});

type Recorded = { id: string; resolvedAt: Date | null; write: DoubleBillingIncidentWrite };

function memoryStore(input: {
  apple: Record<string, AppleEntitlementRow[]>;
  stripe: Record<string, StripeRecurringSubscription[]>;
  failFor?: string;
}): DoubleBillingStore & { incidents: Recorded[] } {
  const incidents: Recorded[] = [];
  return {
    incidents,
    appleSubscriptions: async (userId) => {
      if (userId === input.failFor) throw new Error("db down");
      return input.apple[userId] ?? [];
    },
    stripeSubscriptions: async (userId) => input.stripe[userId] ?? [],
    recordIncident: async (write) => {
      const existing = incidents.find((row) => row.write.userId === write.userId &&
        row.write.stripeSubscriptionId === write.stripeSubscriptionId &&
        row.write.appleOriginalTransactionId === write.appleOriginalTransactionId);
      if (!existing) {
        const id = `inc-${incidents.length + 1}`;
        incidents.push({ id, resolvedAt: null, write });
        return { id, opened: true };
      }
      const opened = existing.resolvedAt !== null;
      existing.resolvedAt = null;
      existing.write = write;
      return { id: existing.id, opened };
    },
    usersWithBothSources: async () => Object.keys(input.stripe).filter((user) => input.apple[user] || user === input.failFor),
    resolveIncidentsExcept: async ({ keepIds, keepUserIds, now }) => {
      let count = 0;
      for (const row of incidents) {
        if (row.resolvedAt || keepIds.includes(row.id) || keepUserIds.includes(row.write.userId)) continue;
        row.resolvedAt = now;
        count += 1;
      }
      return count;
    },
    listIncidents: async () => [],
  };
}

let events: ServerEventInput[];
let alerts: Array<{ error: Error; context: Record<string, unknown> }>;

function deps(store: DoubleBillingStore, now: Date = NOW): DoubleBillingDependencies {
  return {
    store,
    captureEvent: async (input) => { events.push(input); },
    alert: (error, context) => { alerts.push({ error, context }); },
    now: () => now,
  };
}

beforeEach(() => {
  events = [];
  alerts = [];
});

describe("detectDoubleBillingForUser", () => {
  test("opens one incident per Stripe and App Store pair, alerts, and sends one analytics event each", async () => {
    const store = memoryStore({ apple: { u1: [apple()] }, stripe: { u1: [stripeSub] } });
    const results = await detectDoubleBillingForUser("u1", "stripe_checkout", deps(store));
    expect(results.map((result) => result.opened)).toEqual([true]);
    expect(store.incidents[0]!.write).toMatchObject({
      userId: "u1", stripeSubscriptionId: "sub_1", appleOriginalTransactionId: "otx-1",
      applePlanId: "pro", appleStatus: "active", appleEnvironment: "Production", detectedBy: "stripe_checkout",
    });
    expect(alerts).toHaveLength(1);
    expect(alerts[0]!.error.name).toBe("DoubleBillingDetectedError");
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      event: "billing_double_subscription_detected",
      distinctId: "u1",
      properties: { incident_id: "inc-1", detected_by: "stripe_checkout", stripe_subscription_id: "sub_1", apple_original_transaction_id: "otx-1" },
    });
  });

  test("a repeat detection updates the incident without a second alert or event", async () => {
    const store = memoryStore({ apple: { u1: [apple()] }, stripe: { u1: [stripeSub] } });
    await detectDoubleBillingForUser("u1", "stripe_checkout", deps(store));
    await detectDoubleBillingForUser("u1", "apple_transaction", deps(store));
    expect(store.incidents).toHaveLength(1);
    expect(store.incidents[0]!.write.detectedBy).toBe("apple_transaction");
    expect(alerts).toHaveLength(1);
    expect(events).toHaveLength(1);
  });

  test("records nothing without both an active Stripe subscription and an App Store row that may bill", async () => {
    for (const store of [
      memoryStore({ apple: { u1: [apple()] }, stripe: {} }),
      memoryStore({ apple: {}, stripe: { u1: [stripeSub] } }),
      memoryStore({ apple: { u1: [apple({ environment: "Sandbox" })] }, stripe: { u1: [stripeSub] } }),
      memoryStore({ apple: { u1: [apple({ status: "expired", expiresAt: new Date(NOW.getTime() - DAY) })] }, stripe: { u1: [stripeSub] } }),
    ]) {
      expect(await detectDoubleBillingForUser("u1", "daily_scan", deps(store))).toEqual([]);
      expect(store.incidents).toEqual([]);
    }
    expect(alerts).toEqual([]);
    expect(events).toEqual([]);
  });

  test("a failing analytics or alert transport never loses the incident", async () => {
    const store = memoryStore({ apple: { u1: [apple()] }, stripe: { u1: [stripeSub] } });
    const results = await detectDoubleBillingForUser("u1", "stripe_checkout", {
      store,
      captureEvent: async () => { throw new Error("analytics down"); },
      alert: () => { throw new Error("alerts down"); },
      now: () => NOW,
    });
    expect(results).toHaveLength(1);
    expect(store.incidents).toHaveLength(1);
  });
});

describe("reportDoubleBillingForUser", () => {
  test("never throws on a storage failure", async () => {
    const store = memoryStore({ apple: {}, stripe: {}, failFor: "u1" });
    await expect(reportDoubleBillingForUser("u1", "stripe_checkout", deps(store))).resolves.toBeUndefined();
  });
});

describe("scanDoubleBilling", () => {
  test("opens new incidents, keeps repeats, and resolves pairs that stopped billing twice", async () => {
    const appleRows: Record<string, AppleEntitlementRow[]> = { u1: [apple()], u2: [apple({ originalTransactionId: "otx-2" })] };
    const store = memoryStore({ apple: appleRows, stripe: { u1: [stripeSub], u2: [{ id: "sub_2", plan: "max", status: "past_due" }] } });
    expect(await scanDoubleBilling(deps(store))).toEqual({ users: 2, openIncidents: 2, newIncidents: 2, resolvedIncidents: 0, failedUsers: 0 });

    // u2 cancels in the App Store and the subscription expires.
    appleRows.u2 = [apple({ originalTransactionId: "otx-2", status: "expired", expiresAt: new Date(NOW.getTime() - DAY) })];
    const later = new Date(NOW.getTime() + DAY);
    expect(await scanDoubleBilling(deps(store, later))).toEqual({ users: 2, openIncidents: 1, newIncidents: 0, resolvedIncidents: 1, failedUsers: 0 });
    expect(store.incidents.find((row) => row.write.userId === "u2")!.resolvedAt).toEqual(later);
    expect(events.filter((event) => event.event === "billing_double_subscription_detected")).toHaveLength(2);
    expect(events.filter((event) => event.event === "billing_double_subscription_scan")).toHaveLength(2);
  });

  test("a resolved incident that bills twice again reopens and announces again", async () => {
    const appleRows: Record<string, AppleEntitlementRow[]> = { u1: [apple()] };
    const store = memoryStore({ apple: appleRows, stripe: { u1: [stripeSub] } });
    await scanDoubleBilling(deps(store));
    appleRows.u1 = [apple({ status: "expired", expiresAt: new Date(NOW.getTime() - DAY) })];
    await scanDoubleBilling(deps(store));
    appleRows.u1 = [apple()];
    const result = await scanDoubleBilling(deps(store, new Date(NOW.getTime() + 2 * DAY)));
    expect(result.newIncidents).toBe(1);
    expect(alerts).toHaveLength(2);
  });

  test("a user whose check failed keeps their open incidents", async () => {
    const store = memoryStore({ apple: { u1: [apple()] }, stripe: { u1: [stripeSub] } });
    await scanDoubleBilling(deps(store));
    const failing = { ...store, appleSubscriptions: async () => { throw new Error("db down"); } };
    const result = await scanDoubleBilling(deps(failing));
    expect(result).toMatchObject({ failedUsers: 1, resolvedIncidents: 0 });
    expect(store.incidents[0]!.resolvedAt).toBeNull();
  });
});

describe("GET /api/cron/billing-double-subscriptions", () => {
  test("refuses a request without the cron secret before reading anything", async () => {
    const previous = process.env.CRON_SECRET;
    process.env.CRON_SECRET = "cron-secret";
    try {
      const { GET } = await import("../app/api/cron/billing-double-subscriptions/route");
      const response = await GET(new Request("https://cmux.test/api/cron/billing-double-subscriptions", {
        headers: { authorization: "Bearer wrong" },
      }));
      expect(response.status).toBe(401);
    } finally {
      if (previous === undefined) delete process.env.CRON_SECRET;
      else process.env.CRON_SECRET = previous;
    }
  });
});
