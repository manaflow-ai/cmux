import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";

const originalSkipEnvValidation = process.env.SKIP_ENV_VALIDATION;
const originalPostHogProjectKey = process.env.POSTHOG_PROJECT_KEY;
const originalClientConfigRateLimitId = process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID;
process.env.SKIP_ENV_VALIDATION = "1";
process.env.POSTHOG_PROJECT_KEY = "test-project-key";
process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = "cmux-client-config-test";

const originalVercel = process.env.VERCEL;
const checkRateLimit = mock(async () => ({ rateLimited: false, error: null }));

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

const {
  normalizePostHogFlagsResponse,
  postHogFlagsBody,
  postHogFlagsUrl,
} = await import("../services/client-config/posthogFlags");
const { POST } = await import("../app/api/client-config/route");

const originalFetch = globalThis.fetch;
const originalConsoleError = console.error;

afterEach(() => {
  globalThis.fetch = originalFetch;
  console.error = originalConsoleError;
  process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = "cmux-client-config-test";
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
  if (typeof originalVercel === "undefined") {
    delete process.env.VERCEL;
  } else {
    process.env.VERCEL = originalVercel;
  }
});

afterAll(() => {
  restoreEnv("SKIP_ENV_VALIDATION", originalSkipEnvValidation);
  restoreEnv("POSTHOG_PROJECT_KEY", originalPostHogProjectKey);
  restoreEnv("CMUX_CLIENT_CONFIG_RATE_LIMIT_ID", originalClientConfigRateLimitId);
});

describe("client config", () => {
  test("normalizes detailed PostHog flag responses", () => {
    const config = normalizePostHogFlagsResponse({
      errorsWhileComputingFlags: false,
      requestId: "request-1",
      flags: {
        "pricing-page-copy": {
          enabled: true,
          variant: "checkout-a",
          metadata: { payload: { cta: "Start" } },
        },
        "pricing-page-string-payload": {
          enabled: true,
          variant: "checkout-b",
          metadata: { payload: "{\"cta\":\"Keep as text\"}" },
        },
        "pricing-page-visible": {
          enabled: false,
          variant: null,
          metadata: { payload: null },
        },
        "pricing-page-disabled-variant": {
          enabled: false,
          variant: "checkout-b",
          metadata: { payload: "{\"cta\":\"Disabled\"}" },
        },
        "pricing-page-failed": {
          enabled: false,
          failed: true,
          metadata: { payload: "{\"cta\":\"Broken\"}" },
        },
      },
    });

    expect(config).toEqual({
      errorsWhileComputingFlags: false,
      requestId: "request-1",
      featureFlags: {
        "pricing-page-copy": "checkout-a",
        "pricing-page-string-payload": "checkout-b",
        "pricing-page-visible": false,
        "pricing-page-disabled-variant": false,
      },
      featureFlagPayloads: {
        "pricing-page-copy": { cta: "Start" },
        "pricing-page-string-payload": "{\"cta\":\"Keep as text\"}",
      },
    });
  });

  test("preserves legacy PostHog payload values", () => {
    const config = normalizePostHogFlagsResponse({
      errorsWhileComputingFlags: false,
      featureFlags: {
        "pricing-page-copy": "checkout-a",
        "pricing-page-hidden": false,
      },
      featureFlagPayloads: {
        "pricing-page-copy": { cta: "Start" },
        "pricing-page-payload-only": "{\"plan\":\"team\"}",
      },
    });

    expect(config).toEqual({
      errorsWhileComputingFlags: false,
      featureFlags: {
        "pricing-page-copy": "checkout-a",
        "pricing-page-hidden": false,
        "pricing-page-payload-only": true,
      },
      featureFlagPayloads: {
        "pricing-page-copy": { cta: "Start" },
        "pricing-page-payload-only": "{\"plan\":\"team\"}",
      },
    });
  });

  test("lets detailed disabled and failed flags suppress legacy payloads", () => {
    const config = normalizePostHogFlagsResponse({
      errorsWhileComputingFlags: false,
      featureFlags: {
        "pricing-page-disabled": "checkout-a",
        "pricing-page-failed": true,
        "pricing-page-legacy-disabled": false,
      },
      featureFlagPayloads: {
        "pricing-page-disabled": { cta: "Disabled" },
        "pricing-page-failed": { cta: "Failed" },
        "pricing-page-payload-only": "{\"plan\":\"team\"}",
        "pricing-page-legacy-disabled": { cta: "Legacy disabled" },
        "pricing-page-legacy-payload-only": { cta: "Legacy payload" },
      },
      flags: {
        "pricing-page-disabled": {
          enabled: false,
          variant: "checkout-b",
          metadata: { payload: { cta: "Should not leak" } },
        },
        "pricing-page-failed": {
          enabled: true,
          failed: true,
          metadata: { payload: { cta: "Should not leak" } },
        },
      },
    });

    expect(config).toEqual({
      errorsWhileComputingFlags: false,
      featureFlags: {
        "pricing-page-disabled": false,
        "pricing-page-legacy-disabled": false,
        "pricing-page-payload-only": true,
        "pricing-page-legacy-payload-only": true,
      },
      featureFlagPayloads: {
        "pricing-page-payload-only": "{\"plan\":\"team\"}",
        "pricing-page-legacy-payload-only": { cta: "Legacy payload" },
      },
    });
  });

  test("forwards route requests to PostHog flags from the server", async () => {
    const fetchCalls: Array<[RequestInfo | URL, RequestInit | undefined]> = [];
    const fetchMock = mock(async (...args: unknown[]) => {
      fetchCalls.push([args[0] as RequestInfo | URL, args[1] as RequestInit | undefined]);
      return new Response(
        JSON.stringify({
          errorsWhileComputingFlags: false,
          featureFlags: { "pricing-page-visible": true },
          featureFlagPayloads: { "pricing-page-visible": { plan: "team" } },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await POST(new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        distinctId: "browser-id",
        context: {
          groups: { organization: "org-1" },
          personProperties: { plan: "pro" },
          groupProperties: { organization: { tier: "team" } },
          anonDistinctId: "anon-id",
          deviceId: "device-id",
          timezone: "America/Los_Angeles",
          evaluationContexts: ["web"],
        },
      }),
    }));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      errorsWhileComputingFlags: false,
      featureFlags: { "pricing-page-visible": true },
      featureFlagPayloads: { "pricing-page-visible": { plan: "team" } },
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const fetchCall = fetchCalls[0];
    expect(fetchCall?.[0]).toBe(postHogFlagsUrl());
    const fetchInit = fetchCall?.[1] as RequestInit | undefined;
    expect(fetchInit).toMatchObject({
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: postHogFlagsBody("browser-id", {
        groups: { organization: "org-1" },
        personProperties: { plan: "pro" },
        groupProperties: { organization: { tier: "team" } },
        anonDistinctId: "anon-id",
        deviceId: "device-id",
        timezone: "America/Los_Angeles",
        evaluationContexts: ["web"],
      }),
      cache: "no-store",
    });
    expect(fetchInit?.signal).toBeInstanceOf(AbortSignal);
  });

  test("treats quota-limited or flagless upstream responses as unavailable", async () => {
    for (const upstreamBody of [
      { quotaLimited: true },
      { flags: {}, quotaLimited: ["feature_flags"] },
      { requestId: "request-without-flags" },
    ]) {
      const fetchMock = mock(async () => new Response(
        JSON.stringify(upstreamBody),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ));
      globalThis.fetch = fetchMock as unknown as typeof fetch;

      const response = await POST(new Request("https://cmux.test/api/client-config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ distinctId: "browser-id" }),
      }));

      expect(response.status).toBe(502);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(await response.json()).toEqual({ error: "client_config_unavailable" });
    }
  });

  test("applies the Vercel limiter before proxying flags", async () => {
    process.env.VERCEL = "1";
    process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = " cmux-client-config-test\n";
    checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });
    const fetchMock = mock(async () => {
      throw new Error("PostHog flags should not be reached after a rate-limit block");
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await POST(new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{",
    }));

    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({ error: "rate_limited" });
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    const calls = (checkRateLimit as unknown as {
      mock: { calls: Array<[string, { request: Request }]> };
    }).mock.calls;
    expect(calls[0]?.[0]).toBe("cmux-client-config-test");
    expect(calls[0]?.[1]?.request.url).toBe("https://cmux.test/api/client-config");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("fails closed on Vercel when the client-config limiter is missing", async () => {
    process.env.VERCEL = "1";
    delete process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID;
    const consoleError = mock(() => {});
    console.error = consoleError as unknown as typeof console.error;
    const fetchMock = mock(async () => {
      throw new Error("PostHog flags should not be reached without a rate-limit rule");
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await POST(new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ distinctId: "browser-id" }),
    }));

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "client_config_unavailable" });
    expect(consoleError).toHaveBeenCalledWith("client-config.route.rate_limit_not_configured");
    expect(checkRateLimit).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("fails closed on Vercel when the client-config limiter rule is not found", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "not-found" });
    const consoleError = mock(() => {});
    console.error = consoleError as unknown as typeof console.error;
    const fetchMock = mock(async () => {
      throw new Error("PostHog flags should not be reached without a valid rate-limit rule");
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await POST(new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ distinctId: "browser-id" }),
    }));

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "client_config_unavailable" });
    expect(consoleError).toHaveBeenCalledWith(
      "client-config.route.rate_limit_not_found",
      "cmux-client-config-test",
    );
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("fails closed on Vercel when the client-config limiter returns an error", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "firewall-unavailable" });
    const consoleError = mock(() => {});
    console.error = consoleError as unknown as typeof console.error;
    const fetchMock = mock(async () => {
      throw new Error("PostHog flags should not be reached after a limiter error");
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await POST(new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ distinctId: "browser-id" }),
    }));

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "client_config_unavailable" });
    expect(consoleError).toHaveBeenCalledWith(
      "client-config.route.rate_limit_error",
      "firewall-unavailable",
    );
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

function restoreEnv(key: string, value: string | undefined): void {
  if (typeof value === "undefined") {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}
