import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import type { AnalyticsQuery, SubscriptionAnalyticsReport } from "../services/billing/analytics/query";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

type StackUser = {
  id: string;
  primaryEmail: string | null;
  primaryEmailVerified: boolean;
  isAnonymous: boolean;
};

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
  cloudDb: () => ({
    select: () => ({
      from: () => ({
        where: () => ({ limit: async () => [] }),
      }),
    }),
  }),
}));

const { createSubscriptionAnalyticsHandlers } = await import("../app/api/admin/subscriptions/analytics/handlers");

const NOW = new Date("2026-10-02T00:00:00.000Z");
const load = mock(async (query: AnalyticsQuery) => ({ marker: "report", filters: query }) as unknown as SubscriptionAnalyticsReport);
const { GET } = createSubscriptionAnalyticsHandlers({ load, now: () => NOW });

function request(search = ""): NextRequest {
  return new NextRequest(`https://cmux.com/api/admin/subscriptions/analytics${search}`);
}

describe("GET /api/admin/subscriptions/analytics", () => {
  beforeEach(() => {
    currentUser = null;
    load.mockClear();
  });

  test("401 for a signed-out caller, before any read", async () => {
    const response = await GET(request());
    expect(response.status).toBe(401);
    expect(load).not.toHaveBeenCalled();
  });

  test("401 for an anonymous caller", async () => {
    currentUser = { id: "anon", primaryEmail: null, primaryEmailVerified: false, isAnonymous: true };
    expect((await GET(request())).status).toBe(401);
    expect(load).not.toHaveBeenCalled();
  });

  test("403 for a non-admin and for an unverified company email", async () => {
    currentUser = { id: "u1", primaryEmail: "someone@example.com", primaryEmailVerified: true, isAnonymous: false };
    expect((await GET(request())).status).toBe(403);
    currentUser = { id: "u2", primaryEmail: "spoof@manaflow.ai", primaryEmailVerified: false, isAnonymous: false };
    expect((await GET(request())).status).toBe(403);
    expect(load).not.toHaveBeenCalled();
  });

  test("admin gets the report, never cached", async () => {
    currentUser = { id: "admin", primaryEmail: "ops@manaflow.ai", primaryEmailVerified: true, isAnonymous: false };
    const response = await GET(request("?source=apple&plan=pro&granularity=month"));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json() as { marker: string };
    expect(body.marker).toBe("report");
    const [query, now] = load.mock.calls[0]! as unknown as [AnalyticsQuery, Date];
    expect(query.source).toBe("apple");
    expect(query.plan).toBe("pro");
    expect(query.environment).toBe("production");
    expect(query.granularity).toBe("month");
    expect(now).toBe(NOW);
  });

  test("400 for an invalid filter from an admin", async () => {
    currentUser = { id: "admin", primaryEmail: "ops@cmux.com", primaryEmailVerified: true, isAnonymous: false };
    expect((await GET(request("?environment=staging"))).status).toBe(400);
    expect(load).not.toHaveBeenCalled();
  });

  test("503 when the loader fails", async () => {
    currentUser = { id: "admin", primaryEmail: "ops@cmux.com", primaryEmailVerified: true, isAnonymous: false };
    const failing = createSubscriptionAnalyticsHandlers({
      load: async () => {
        throw new Error("db down");
      },
      now: () => NOW,
    });
    expect((await failing.GET(request())).status).toBe(503);
  });
});
