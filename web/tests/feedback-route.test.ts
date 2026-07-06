const priorSkipEnvValidation = process.env.SKIP_ENV_VALIDATION;
const priorResendApiKey = process.env.RESEND_API_KEY;
const priorFeedbackFromEmail = process.env.CMUX_FEEDBACK_FROM_EMAIL;
const priorFeedbackRateLimitId = process.env.CMUX_FEEDBACK_RATE_LIMIT_ID;
const priorVercel = process.env.VERCEL;

process.env.SKIP_ENV_VALIDATION = "1";
process.env.RESEND_API_KEY = "resend-test-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL = "feedback@example.test";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID = "feedback-rate-limit-test";

import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";

const checkRateLimit = mock(async () => ({ rateLimited: false, error: null as string | null }));
const sendEmail = mock(async () => ({ data: { id: "email-1" }, error: null }));

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

mock.module("@/app/env", () => ({
  env: {
    RESEND_API_KEY: "resend-test-key",
    CMUX_FEEDBACK_FROM_EMAIL: "feedback@example.test",
    CMUX_FEEDBACK_RATE_LIMIT_ID: "feedback-rate-limit-test",
  },
}));

mock.module("resend", () => ({
  Resend: class {
    readonly emails = { send: sendEmail };
  },
}));

const { POST } = await import("../app/api/feedback/route");

afterEach(() => {
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
  sendEmail.mockClear();
  if (priorVercel === undefined) {
    delete process.env.VERCEL;
  } else {
    process.env.VERCEL = priorVercel;
  }
});

afterAll(() => {
  restoreEnv("SKIP_ENV_VALIDATION", priorSkipEnvValidation);
  restoreEnv("RESEND_API_KEY", priorResendApiKey);
  restoreEnv("CMUX_FEEDBACK_FROM_EMAIL", priorFeedbackFromEmail);
  restoreEnv("CMUX_FEEDBACK_RATE_LIMIT_ID", priorFeedbackRateLimitId);
  restoreEnv("VERCEL", priorVercel);
});

describe("feedback route", () => {
  test("fails closed when the Vercel firewall rule is missing", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "not-found" });

    const res = await POST(feedbackRequest());

    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "Rate limit unavailable" });
    expect(sendEmail).not.toHaveBeenCalled();
  });

  test("fails closed when the Vercel firewall check errors", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "firewall-unavailable" });

    const res = await POST(feedbackRequest());

    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "Rate limit unavailable" });
    expect(sendEmail).not.toHaveBeenCalled();
  });
});

function feedbackRequest(): Request {
  const form = new FormData();
  form.set("email", "user@example.test");
  form.set("message", "The app crashed while opening a workspace.");
  return new Request("https://cmux.test/api/feedback", {
    method: "POST",
    body: form,
  });
}

function restoreEnv(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
    return;
  }
  process.env[key] = value;
}
