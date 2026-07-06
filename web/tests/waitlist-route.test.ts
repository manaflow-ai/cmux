// Skip env validation so importing the route doesn't require server secrets.
// Captured + restored in afterAll so the flag can't leak into other test files
// sharing this process and silently suppress their env validation.
const envKeys = [
  "SKIP_ENV_VALIDATION",
  "VERCEL",
  "CMUX_FEEDBACK_RATE_LIMIT_ID",
  "SLACK_WAITLIST_WEBHOOK_URL",
] as const;
const priorEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]])) as Record<
  (typeof envKeys)[number],
  string | undefined
>;
process.env.SKIP_ENV_VALIDATION = "1";
process.env.VERCEL = "1";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID = "feedback-rule";
delete process.env.SLACK_WAITLIST_WEBHOOK_URL;

import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

type RateLimitResult = {
  error?: string | null;
  rateLimited?: boolean;
};

let rateLimitResult: RateLimitResult = { rateLimited: false, error: null };
const checkRateLimit = mock(async () => rateLimitResult);
const checkEmailDeliverable = mock(async () => "ok" as const);

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

mock.module("../app/api/waitlist/email-check", () => ({
  checkEmailDeliverable,
}));

const { POST } = await import("../app/api/waitlist/route");

afterAll(() => {
  for (const key of envKeys) {
    const value = priorEnv[key];
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
});

beforeEach(() => {
  process.env.SKIP_ENV_VALIDATION = "1";
  process.env.VERCEL = "1";
  process.env.CMUX_FEEDBACK_RATE_LIMIT_ID = "feedback-rule";
  delete process.env.SLACK_WAITLIST_WEBHOOK_URL;
  rateLimitResult = { rateLimited: false, error: null };
  checkRateLimit.mockClear();
  checkEmailDeliverable.mockClear();
  checkEmailDeliverable.mockResolvedValue("ok");
});

function post(body: unknown = { email: "a@example.com", platforms: ["linux"], notify: true }): Request {
  return new Request("https://cmux.test/api/waitlist", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("waitlist route", () => {
  test("accepts a deliverable email in the validate phase", async () => {
    const res = await POST(
      post({ email: "a@example.com", platforms: ["linux"], notify: false }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      ok: true,
      valid: true,
      slack: "skipped",
    });
    expect(checkEmailDeliverable).toHaveBeenCalledWith("a@example.com");
  });

  test("rejects an undeliverable email without recording", async () => {
    checkEmailDeliverable.mockResolvedValue("invalid");

    const res = await POST(
      post({ email: "a@example.com", platforms: ["linux"], notify: false }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, valid: false });
    expect(checkEmailDeliverable).toHaveBeenCalledWith("a@example.com");
  });

  test("rejects a disposable email", async () => {
    checkEmailDeliverable.mockResolvedValue("invalid");

    const res = await POST(
      post({ email: "a@mailinator.com", platforms: ["windows"] }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, valid: false });
    expect(checkEmailDeliverable).toHaveBeenCalledWith("a@mailinator.com");
  });

  test("rejects a malformed payload with 400", async () => {
    const res = await POST(post({ email: "not-an-email", platforms: [] }));
    expect(res.status).toBe(400);
  });

  test("fails closed without DNS validation when the Vercel limiter rule is missing", async () => {
    rateLimitResult = { rateLimited: false, error: "not-found" };

    const res = await POST(post());

    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "Rate limiter unavailable" });
    expect(checkEmailDeliverable).not.toHaveBeenCalled();
  });

  test("fails closed without DNS validation when the Vercel limiter returns an error", async () => {
    rateLimitResult = { rateLimited: false, error: "unknown" };

    const res = await POST(post());

    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "Rate limiter unavailable" });
    expect(checkEmailDeliverable).not.toHaveBeenCalled();
  });

  test("keeps blocked limiter results as 429 without DNS validation", async () => {
    rateLimitResult = { rateLimited: false, error: "blocked" };

    const res = await POST(post());

    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "Rate limit exceeded" });
    expect(checkEmailDeliverable).not.toHaveBeenCalled();
  });

  test("continues to DNS validation when the Vercel limiter allows the request", async () => {
    rateLimitResult = { rateLimited: false, error: null };
    checkEmailDeliverable.mockResolvedValue("ok");

    const res = await POST(post());

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      ok: true,
      valid: true,
      slack: "skipped",
    });
    expect(checkEmailDeliverable).toHaveBeenCalledWith("a@example.com");
  });
});
