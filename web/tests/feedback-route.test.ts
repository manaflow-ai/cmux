import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";

const originalSkipEnvValidation = process.env.SKIP_ENV_VALIDATION;
const originalResendApiKey = process.env.RESEND_API_KEY;
const originalFeedbackFromEmail = process.env.CMUX_FEEDBACK_FROM_EMAIL;
const originalFeedbackRateLimitId = process.env.CMUX_FEEDBACK_RATE_LIMIT_ID;
process.env.SKIP_ENV_VALIDATION = "1";
process.env.RESEND_API_KEY = "test-resend-api-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL = "feedback-from@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID = "cmux-feedback-test";

const originalVercel = process.env.VERCEL;
const originalConsoleError = console.error;
const checkRateLimit = mock(async () => ({ rateLimited: false, error: null }));
const emailSendMock = mock(async () => ({ error: null }));

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

mock.module("resend", () => ({
  Resend: class {
    emails = { send: emailSendMock };
  },
}));

const { POST } = await import("../app/api/feedback/route");

afterEach(() => {
  console.error = originalConsoleError;
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
  emailSendMock.mockClear();
  emailSendMock.mockResolvedValue({ error: null });
  if (typeof originalVercel === "undefined") {
    delete process.env.VERCEL;
  } else {
    process.env.VERCEL = originalVercel;
  }
});

afterAll(() => {
  restoreEnv("SKIP_ENV_VALIDATION", originalSkipEnvValidation);
  restoreEnv("RESEND_API_KEY", originalResendApiKey);
  restoreEnv("CMUX_FEEDBACK_FROM_EMAIL", originalFeedbackFromEmail);
  restoreEnv("CMUX_FEEDBACK_RATE_LIMIT_ID", originalFeedbackRateLimitId);
});

describe("feedback route", () => {
  test("fails closed on Vercel when the feedback limiter rule is not found", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "not-found" });
    const consoleError = mock(() => {});
    console.error = consoleError as unknown as typeof console.error;

    const response = await POST(feedbackRequest());

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: "Feedback endpoint is not configured",
    });
    expect(emailSendMock).not.toHaveBeenCalled();
    expect(consoleError).toHaveBeenCalledWith(
      "feedback.route.rate_limit_not_found",
      "cmux-feedback-test",
    );
  });

  test("fails closed on Vercel when the feedback limiter returns an error", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({
      rateLimited: false,
      error: "firewall-unavailable",
    });
    const consoleError = mock(() => {});
    console.error = consoleError as unknown as typeof console.error;

    const response = await POST(feedbackRequest());

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: "Feedback endpoint is not configured",
    });
    expect(emailSendMock).not.toHaveBeenCalled();
    expect(consoleError).toHaveBeenCalledWith(
      "feedback.route.rate_limit_error",
      "firewall-unavailable",
    );
  });

  test("sends feedback when the limiter is healthy on Vercel", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    emailSendMock.mockResolvedValue({ error: null });

    const response = await POST(feedbackRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(emailSendMock).toHaveBeenCalledTimes(1);
  });
});

function feedbackRequest(): Request {
  const formData = new FormData();
  formData.set("email", "reporter@example.com");
  formData.set("message", "The app should send this only when rate limiting is healthy.");

  return new Request("https://cmux.test/api/feedback", {
    method: "POST",
    body: formData,
  });
}

function restoreEnv(key: string, value: string | undefined): void {
  if (typeof value === "undefined") {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}
