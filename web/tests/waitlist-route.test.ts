// Skip env validation so importing the route doesn't require server secrets.
// Captured + restored in afterAll so the flag can't leak into other test files
// sharing this process and silently suppress their env validation.
const priorSkipEnvValidation = process.env.SKIP_ENV_VALIDATION;
const priorFeedbackRateLimitId = process.env.CMUX_FEEDBACK_RATE_LIMIT_ID;
const priorVercel = process.env.VERCEL;
process.env.SKIP_ENV_VALIDATION = "1";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID = "feedback-rate-limit-test";

import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";

afterAll(() => {
  if (priorSkipEnvValidation === undefined) {
    delete process.env.SKIP_ENV_VALIDATION;
  } else {
    process.env.SKIP_ENV_VALIDATION = priorSkipEnvValidation;
  }
  if (priorFeedbackRateLimitId === undefined) {
    delete process.env.CMUX_FEEDBACK_RATE_LIMIT_ID;
  } else {
    process.env.CMUX_FEEDBACK_RATE_LIMIT_ID = priorFeedbackRateLimitId;
  }
  if (priorVercel === undefined) {
    delete process.env.VERCEL;
  } else {
    process.env.VERCEL = priorVercel;
  }
});

function dnsError(code: string): NodeJS.ErrnoException {
  const err = new Error(code) as NodeJS.ErrnoException;
  err.code = code;
  return err;
}

// good.test has an MX; everything else has no records (undeliverable).
mock.module("node:dns", () => ({
  promises: {
    resolveMx: async (domain: string) => {
      if (domain === "good.test") {
        return [{ exchange: "mx.good.test", priority: 10 }];
      }
      throw dnsError("ENOTFOUND");
    },
    resolve4: async () => {
      throw dnsError("ENOTFOUND");
    },
    resolve6: async () => {
      throw dnsError("ENOTFOUND");
    },
  },
}));

const checkRateLimit = mock(async () => ({ rateLimited: false, error: null as string | null }));

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

mock.module("@/app/env", () => ({
  env: {
    CMUX_FEEDBACK_RATE_LIMIT_ID: "feedback-rate-limit-test",
    SLACK_WAITLIST_WEBHOOK_URL: undefined,
  },
}));

const { POST } = await import("../app/api/waitlist/route");

function post(body: unknown): Request {
  return new Request("https://cmux.test/api/waitlist", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("waitlist route", () => {
  afterEach(() => {
    checkRateLimit.mockClear();
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    if (priorVercel === undefined) {
      delete process.env.VERCEL;
    } else {
      process.env.VERCEL = priorVercel;
    }
  });

  test("accepts a deliverable email in the validate phase", async () => {
    const res = await POST(
      post({ email: "a@good.test", platforms: ["linux"], notify: false }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      ok: true,
      valid: true,
      slack: "skipped",
    });
  });

  test("rejects an undeliverable email without recording", async () => {
    const res = await POST(
      post({ email: "a@nope.test", platforms: ["linux"], notify: false }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, valid: false });
  });

  test("rejects a disposable email", async () => {
    const res = await POST(
      post({ email: "a@mailinator.com", platforms: ["windows"] }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, valid: false });
  });

  test("rejects a malformed payload with 400", async () => {
    const res = await POST(post({ email: "not-an-email", platforms: [] }));
    expect(res.status).toBe(400);
  });

  test("fails closed when the Vercel firewall rule is missing", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "not-found" });

    const res = await POST(
      post({ email: "a@good.test", platforms: ["linux"], notify: false }),
    );

    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "Rate limit unavailable" });
  });

  test("fails closed when the Vercel firewall check errors", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "firewall-unavailable" });

    const res = await POST(
      post({ email: "a@good.test", platforms: ["linux"], notify: false }),
    );

    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "Rate limit unavailable" });
  });
});
