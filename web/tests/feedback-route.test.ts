import { afterAll, afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

const envKeys = [
  "SKIP_ENV_VALIDATION",
  "RESEND_API_KEY",
  "CMUX_FEEDBACK_FROM_EMAIL",
  "CMUX_FEEDBACK_RATE_LIMIT_ID",
  "STACK_SECRET_SERVER_KEY",
  "NEXT_PUBLIC_STACK_PROJECT_ID",
  "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
] as const;
const originalEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]])) as Record<
  (typeof envKeys)[number],
  string | undefined
>;

process.env.SKIP_ENV_VALIDATION = "1";
process.env.RESEND_API_KEY = "resend-test-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL = "feedback@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID = "feedback-limiter";
process.env.STACK_SECRET_SERVER_KEY = "stack-secret";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "stack-project";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "stack-publishable";

type CheckRateLimitOptions = { request?: Request; rateLimitKey?: string };
type CheckRateLimitResult = { rateLimited: boolean; error: string | null };
type CheckRateLimitHandler = (
  id: string,
  options: CheckRateLimitOptions,
) => Promise<CheckRateLimitResult>;
const checkRateLimit = mock(async (...args: unknown[]): Promise<CheckRateLimitResult> => {
  void args;
  return { rateLimited: false, error: null };
});
const checkRateLimitHandler: CheckRateLimitHandler = (id, options) =>
  checkRateLimit(id, options) as Promise<CheckRateLimitResult>;
const firewallState = globalThis as typeof globalThis & {
  __cmuxFirewallCheckRateLimits?: Map<string, CheckRateLimitHandler>;
};
firewallState.__cmuxFirewallCheckRateLimits ??= new Map();
firewallState.__cmuxFirewallCheckRateLimits.set("feedback-limiter", checkRateLimitHandler);
const send = mock(async () => ({ error: null }));

mock.module("@vercel/firewall", () => ({
  checkRateLimit: (id: string, options: CheckRateLimitOptions) =>
    (firewallState.__cmuxFirewallCheckRateLimits?.get(id) ?? checkRateLimitHandler)(id, options),
}));

mock.module("resend", () => ({
  Resend: class {
    emails = { send };
  },
}));

const feedbackRoute = await import("../app/api/feedback/route");

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
  feedbackRoute.configureFeedbackRateLimitForTests(null);
  firewallState.__cmuxFirewallCheckRateLimits?.delete("feedback-limiter");
  checkRateLimit.mockClear();
  send.mockClear();
});

beforeEach(() => {
  feedbackRoute.configureFeedbackRateLimitForTests("feedback-limiter");
  firewallState.__cmuxFirewallCheckRateLimits ??= new Map();
  firewallState.__cmuxFirewallCheckRateLimits.set("feedback-limiter", checkRateLimitHandler);
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
  send.mockClear();
  send.mockResolvedValue({ error: null });
});

describe("feedback route hardening", () => {
  test("fails closed when the production feedback limiter is unavailable", async () => {
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "not-found" });
    const body = new FormData();
    body.set("email", "user@example.com");
    body.set("message", "hello");

    const response = await feedbackRoute.POST(
      new Request("https://cmux.test/api/feedback", {
        method: "POST",
        body,
      }),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "rate_limiter_unavailable" });
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    expect(send).not.toHaveBeenCalled();
  });

  test("rejects urlencoded feedback bodies before sending email", async () => {
    const response = await feedbackRoute.POST(
      new Request("https://cmux.test/api/feedback", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          email: "user@example.com",
          message: "hello",
        }),
      }),
    );

    expect(response.status).toBe(415);
    expect(await response.json()).toEqual({ error: "Invalid multipart payload" });
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    expect(send).not.toHaveBeenCalled();
  });
});
