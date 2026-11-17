import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import type { DoubleBillingIncident } from "../services/billing/doubleBilling";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

type StackUser = { id: string; primaryEmail: string | null; primaryEmailVerified: boolean; isAnonymous: boolean };

let currentUser: StackUser | null = null;
const getUser = mock(async () => currentUser);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  promoteStackUserFromAnonymousViaApi: async () => undefined,
  stackServerApp: { getUser },
}));

// The invited-member lookup finds nobody, so only company-domain admins pass.
mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => ({ select: () => ({ from: () => ({ where: () => ({ limit: async () => [] }) }) }) }),
}));

const { createDoubleBillingHandlers } = await import("../app/api/admin/subscriptions/double-billing/handlers");

const incident: DoubleBillingIncident = {
  id: "inc-1",
  userId: "user-1",
  stripeSubscriptionId: "sub_1",
  stripePlanId: "pro",
  stripeStatus: "active",
  appleOriginalTransactionId: "otx-1",
  applePlanId: "pro",
  appleStatus: "billing_retry",
  appleEnvironment: "Production",
  appleAutoRenewEnabled: true,
  firstDetectedBy: "stripe_checkout",
  detectedBy: "daily_scan",
  firstDetectedAt: new Date("2026-11-10T00:00:00.000Z"),
  detectedAt: new Date("2026-11-13T00:00:00.000Z"),
  resolvedAt: null,
};
const listIncidents = mock(async (input: { includeResolved: boolean; limit: number }) => (input.limit > 0 ? [incident] : []));
const { GET } = createDoubleBillingHandlers({ store: { listIncidents } });

const admin: StackUser = { id: "admin", primaryEmail: "ops@manaflow.ai", primaryEmailVerified: true, isAnonymous: false };

function request(search = ""): NextRequest {
  return new NextRequest(`https://cmux.com/api/admin/subscriptions/double-billing${search}`);
}

describe("GET /api/admin/subscriptions/double-billing", () => {
  beforeEach(() => {
    currentUser = null;
    listIncidents.mockClear();
  });

  test("401 signed out and 403 for a non-admin, before any read", async () => {
    expect((await GET(request())).status).toBe(401);
    currentUser = { id: "u1", primaryEmail: "someone@example.com", primaryEmailVerified: true, isAnonymous: false };
    expect((await GET(request())).status).toBe(403);
    expect(listIncidents).not.toHaveBeenCalled();
  });

  test("an admin gets open incidents by default, never cached", async () => {
    currentUser = admin;
    const response = await GET(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(listIncidents).toHaveBeenCalledWith({ includeResolved: false, limit: 100 });
    expect(await response.json()).toEqual({
      status: "open",
      incidents: [{ ...incident, firstDetectedAt: "2026-11-10T00:00:00.000Z", detectedAt: "2026-11-13T00:00:00.000Z", resolvedAt: null }],
    });
  });

  test("status=all includes resolved incidents; bad queries are 400", async () => {
    currentUser = admin;
    await GET(request("?status=all&limit=5"));
    expect(listIncidents).toHaveBeenCalledWith({ includeResolved: true, limit: 5 });
    for (const search of ["?status=closed", "?limit=0", "?limit=501", "?limit=abc"]) {
      expect((await GET(request(search))).status).toBe(400);
    }
  });

  test("a storage failure is 503", async () => {
    currentUser = admin;
    const failing = createDoubleBillingHandlers({ store: { listIncidents: async () => { throw new Error("db down"); } } });
    expect((await failing.GET(request())).status).toBe(503);
  });
});
