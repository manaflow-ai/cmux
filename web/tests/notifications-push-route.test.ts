import { afterAll, afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const envKeys = [
  "SKIP_ENV_VALIDATION",
  "CMUX_PUSH_RATE_LIMIT_ID",
] as const;
const originalEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]])) as Record<
  (typeof envKeys)[number],
  string | undefined
>;

process.env.SKIP_ENV_VALIDATION = "1";
process.env.CMUX_PUSH_RATE_LIMIT_ID = "cmux-push-test";

const getUser = mock(async () => ({
  id: "user-1",
  displayName: null,
  primaryEmail: null,
  selectedTeam: null,
}));
type CheckRateLimitOptions = { request?: Request; rateLimitKey?: string };
type CheckRateLimitResult = { rateLimited: boolean; error: string | null };
type CheckRateLimitHandler = (
  id: string,
  options: CheckRateLimitOptions,
) => Promise<CheckRateLimitResult>;
const checkRateLimit = mock(async (...args: unknown[]): Promise<CheckRateLimitResult> => {
  void args;
  return { rateLimited: true, error: null };
});
const checkRateLimitHandler: CheckRateLimitHandler = (id, options) =>
  checkRateLimit(id, options) as Promise<CheckRateLimitResult>;
const firewallState = globalThis as typeof globalThis & {
  __cmuxFirewallCheckRateLimits?: Map<string, CheckRateLimitHandler>;
};
firewallState.__cmuxFirewallCheckRateLimits ??= new Map();
firewallState.__cmuxFirewallCheckRateLimits.set("cmux-push-test", checkRateLimitHandler);
const cloudDb = mock(() => {
  throw new Error("cloudDb should not be reached after a push rate-limit block");
});

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
}));

mock.module("@vercel/firewall", () => ({
  checkRateLimit: (id: string, options: CheckRateLimitOptions) =>
    (firewallState.__cmuxFirewallCheckRateLimits?.get(id) ?? checkRateLimitHandler)(id, options),
}));

mock.module("../db/client", () => ({
  cloudDb,
}));

const pushRoute = await import("../app/api/notifications/push/route");

afterAll(() => {
  for (const key of envKeys) {
    const value = originalEnv[key];
    if (typeof value === "undefined") {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
});

afterEach(() => {
  pushRoute.configurePushRateLimitForTests(null);
  firewallState.__cmuxFirewallCheckRateLimits?.delete("cmux-push-test");
  checkRateLimit.mockClear();
  cloudDb.mockClear();
});

beforeEach(() => {
  pushRoute.configurePushRateLimitForTests("cmux-push-test");
  firewallState.__cmuxFirewallCheckRateLimits ??= new Map();
  firewallState.__cmuxFirewallCheckRateLimits.set("cmux-push-test", checkRateLimitHandler);
  getUser.mockClear();
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });
  cloudDb.mockClear();
});

describe("notifications push route", () => {
  test("applies the Vercel user limiter before body parsing or DB access", async () => {
    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "content-length": "9000",
        },
        body: "{}",
      }),
    );

    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({ error: "rate_limited" });
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    const calls = (checkRateLimit as unknown as {
      mock: { calls: Array<[string, { rateLimitKey: string }]> };
    }).mock.calls;
    expect(calls[0]?.[0]).toBe("cmux-push-test");
    expect(calls[0]?.[1]).toMatchObject({
      rateLimitKey: "user-1",
    });
    expect(cloudDb).not.toHaveBeenCalled();
  });

  test("fails closed when the Vercel user limiter is unavailable", async () => {
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "not-found" });

    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: "{}",
      }),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "rate_limiter_unavailable" });
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    expect(cloudDb).not.toHaveBeenCalled();
  });

  test("fails closed when the production user limiter id is missing", async () => {
    pushRoute.configurePushRateLimitForTests(null, { required: true });

    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: "{}",
      }),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "rate_limiter_unavailable" });
    expect(checkRateLimit).not.toHaveBeenCalled();
    expect(cloudDb).not.toHaveBeenCalled();
  });
});
