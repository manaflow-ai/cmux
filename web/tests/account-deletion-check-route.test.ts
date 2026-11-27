import { beforeEach, describe, expect, mock, test } from "bun:test";

import * as entitlementModule from "../services/billing/apple/entitlement";
import type { AppleEntitlementRow } from "../services/billing/apple/entitlement";

type TestUser = { id: string; isAnonymous: boolean };

let currentUser: TestUser | null = null;
let rowsFor: (userId: string) => Promise<AppleEntitlementRow[]> = async () => [];
const queriedUsers: string[] = [];

mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({ getUser: async () => currentUser }),
}));

const realEntitlement = { ...entitlementModule };
mock.module("../services/billing/apple/entitlement", () => ({
  ...realEntitlement,
  appleSubscriptionRowsForUser: (userId: string) => {
    queriedUsers.push(userId);
    return rowsFor(userId);
  },
}));

const { GET } = await import("../app/api/account/deletion-check/route");

function request(): Request {
  return new Request("https://cmux.test/api/account/deletion-check", {
    headers: { authorization: "Bearer access", "x-stack-refresh-token": "refresh" },
  });
}

function row(overrides: Partial<AppleEntitlementRow> = {}): AppleEntitlementRow {
  return {
    originalTransactionId: "otx-1",
    planId: "pro",
    status: "active",
    environment: "Production",
    bundleId: "com.cmux.app",
    expiresAt: new Date(Date.now() + 86_400_000),
    gracePeriodExpiresAt: null,
    autoRenewEnabled: true,
    ...overrides,
  };
}

beforeEach(() => {
  currentUser = { id: "user-a", isAnonymous: false };
  rowsFor = async () => [];
  queriedUsers.length = 0;
});

describe("GET /api/account/deletion-check", () => {
  test("refuses a signed-out caller", async () => {
    currentUser = null;
    const response = await GET(request());
    expect(response.status).toBe(401);
    expect(queriedUsers).toEqual([]);
  });

  test("reports the caller's renewing App Store subscription with Apple's management link", async () => {
    rowsFor = async () => [row()];
    const response = await GET(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      appStoreSubscriptionRenews: true,
      manageSubscriptionsUrl: "https://apps.apple.com/account/subscriptions",
    });
    expect(queriedUsers).toEqual(["user-a"]);
  });

  test("reports nothing to warn about when auto-renew is off", async () => {
    rowsFor = async () => [row({ autoRenewEnabled: false })];
    expect(await (await GET(request())).json()).toEqual({
      appStoreSubscriptionRenews: false,
      manageSubscriptionsUrl: null,
    });
  });

  test("answers 503 when the subscription rows cannot be read", async () => {
    rowsFor = async () => { throw new Error("db down"); };
    const response = await GET(request());
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "deletion_check_unavailable" });
  });
});
