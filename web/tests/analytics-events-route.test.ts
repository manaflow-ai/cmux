import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

const envKeys = [
  "SKIP_ENV_VALIDATION",
  "VERCEL",
  "CMUX_ANALYTICS_RATE_LIMIT_ID",
] as const;
const originalEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]])) as Record<
  (typeof envKeys)[number],
  string | undefined
>;

process.env.SKIP_ENV_VALIDATION = "1";
process.env.VERCEL = "1";
process.env.CMUX_ANALYTICS_RATE_LIMIT_ID = "cmux-analytics-test";

const getUser = mock(async () => {
  throw new Error("Stack auth should not be reached after an analytics rate-limit block");
});
const checkRateLimit = mock(async () => ({ rateLimited: true, error: null }));
const fetchMock = mock(async () => new Response("{}", { status: 200 }));
const originalFetch = globalThis.fetch;
globalThis.fetch = fetchMock as unknown as typeof fetch;

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

const analyticsRoute = await import("../app/api/analytics/events/route");

afterAll(() => {
  globalThis.fetch = originalFetch;
  for (const key of envKeys) {
    const value = originalEnv[key];
    if (typeof value === "undefined") {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
});

beforeEach(() => {
  process.env.SKIP_ENV_VALIDATION = "1";
  process.env.VERCEL = "1";
  process.env.CMUX_ANALYTICS_RATE_LIMIT_ID = "cmux-analytics-test";
  getUser.mockClear();
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });
  fetchMock.mockClear();
});

describe("analytics events route", () => {
  test("applies the anonymous Vercel limiter before auth, body parsing, or PostHog forwarding", async () => {
    const response = await analyticsRoute.POST(
      new Request("https://cmux.test/api/analytics/events", {
        method: "POST",
        headers: {
          host: "cmux.test",
          "content-type": "application/json",
          "x-real-ip": "203.0.113.10",
        },
        body: "{",
      }),
    );

    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({ error: "rate_limited" });
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    const calls = (checkRateLimit as unknown as {
      mock: { calls: Array<[string, { request: Request; rateLimitKey?: string }]> };
    }).mock.calls;
    expect(calls[0]?.[0]).toBe("cmux-analytics-test");
    expect(calls[0]?.[1].request).toBeInstanceOf(Request);
    expect(calls[0]?.[1].rateLimitKey).toBeUndefined();
    expect(getUser).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
