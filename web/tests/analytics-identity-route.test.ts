import { describe, expect, mock, test } from "bun:test";

import { makeAnalyticsIdentityHandler } from "../app/api/analytics/identity/route";

describe("analytics identity route", () => {
  test("returns only the stable Stack id for signed-in users", async () => {
    const getUser = mock(async () => ({
      id: "stack-user-1",
      isAnonymous: false,
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    }));
    const GET = makeAnalyticsIdentityHandler({
      isConfigured: () => true,
      getUser,
    });

    const response = await GET(new Request("https://cmux.test/api/analytics/identity"));

    expect(response.headers.get("cache-control")).toBe("private, no-store");
    await expect(response.json()).resolves.toEqual({
      user: { id: "stack-user-1", plan: "pro" },
    });
    expect(getUser).toHaveBeenCalledTimes(1);
  });

  test("does not expose anonymous Stack checkout identities", async () => {
    const GET = makeAnalyticsIdentityHandler({
      isConfigured: () => true,
      getUser: async () => ({
        id: "anonymous-stack-user",
        isAnonymous: true,
      }),
    });

    const response = await GET(new Request("https://cmux.test/api/analytics/identity"));

    await expect(response.json()).resolves.toEqual({ user: null });
  });

  test("avoids an auth lookup when Stack is not configured", async () => {
    const getUser = mock(async () => null);
    const GET = makeAnalyticsIdentityHandler({
      isConfigured: () => false,
      getUser,
    });

    const response = await GET(new Request("https://cmux.test/api/analytics/identity"));

    await expect(response.json()).resolves.toEqual({ user: null });
    expect(getUser).not.toHaveBeenCalled();
  });

  test("returns a bounded unavailable response when Stack Auth is down", async () => {
    const GET = makeAnalyticsIdentityHandler({
      isConfigured: () => true,
      getUser: async () => {
        throw new Error("Stack Auth unavailable");
      },
    });

    const response = await GET(
      new Request("https://cmux.test/api/analytics/identity"),
    );

    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    await expect(response.json()).resolves.toEqual({
      error: "analytics_identity_unavailable",
    });
  });
});
