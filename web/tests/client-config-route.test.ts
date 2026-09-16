import { afterAll, afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  checkRateLimit,
  installVercelFirewallMock,
} from "./vercel-firewall-mock";

const originalSkipEnvValidation = process.env.SKIP_ENV_VALIDATION;
const originalPostHogProjectKey = process.env.POSTHOG_PROJECT_KEY;
const originalClientConfigRateLimitId = process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID;
process.env.SKIP_ENV_VALIDATION = "1";
process.env.POSTHOG_PROJECT_KEY = "test-project-key";
process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = "cmux-client-config-test";

const originalVercel = process.env.VERCEL;
const originalVercelEnvironment = process.env.VERCEL_ENV;
const originalNodeEnv = process.env.NODE_ENV;
const originalDeploymentId = process.env.VERCEL_DEPLOYMENT_ID;
const contextSymbol = Symbol.for("@vercel/request-context");
const originalContext = Reflect.get(globalThis, contextSymbol);
const mutableEnv = process.env as Record<string, string | undefined>;
installVercelFirewallMock();

const {
  normalizePostHogFlagsResponse,
  postHogFlagsBody,
  postHogFlagsUrl,
} = await import("../services/client-config/posthogFlags");
const { POST } = await import("../app/api/client-config/route");

const originalFetch = globalThis.fetch;
const originalConsoleError = console.error;

beforeEach(() => {
  process.env.VERCEL_DEPLOYMENT_ID = "client-config-route-tests";
  const entries = new Map<string, unknown>();
  Reflect.set(globalThis, contextSymbol, {
    get: () => ({ cache: {
      get: async (key: string) => entries.get(key),
      set: async (key: string, value: unknown) => { entries.set(key, value); },
    } }),
  });
});

afterEach(() => {
  if (originalContext === undefined) Reflect.deleteProperty(globalThis, contextSymbol);
  else Reflect.set(globalThis, contextSymbol, originalContext);
  restoreEnv("VERCEL_DEPLOYMENT_ID", originalDeploymentId);
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
  restoreEnv("VERCEL_ENV", originalVercelEnvironment);
  restoreEnv("NODE_ENV", originalNodeEnv);
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

  test("partitions the Vercel limiter by deployment and install", async () => {
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "production";
    process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = " cmux-client-config-test\n";
    checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });
    const fetchMock = mock(async () => {
      throw new Error("PostHog flags should not be reached after a rate-limit block");
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await POST(new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ distinctId: "browser-id" }),
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual({ error: "rate_limited" });
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    const calls = (checkRateLimit as unknown as {
      mock: { calls: Array<[string, { request: Request; rateLimitKey?: string }]> };
    }).mock.calls;
    expect(calls[0]?.[0]).toBe("cmux-client-config-test");
    expect(calls[0]?.[1]?.request.url).toBe("https://cmux.test/api/client-config");
    const installPartition = createHash("sha256")
      .update("cmux/client-config/v1\0browser-id")
      .digest("hex");
    expect(calls[0]?.[1]?.rateLimitKey).toBe(`production:${installPartition}`);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("rejects malformed client config before consuming an install budget", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });

    const response = await POST(new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{",
    }));

    expect(response.status).toBe(400);
    expect(checkRateLimit).not.toHaveBeenCalled();
  });

  test("skips rate limiting on Vercel when the client-config limiter id is unset", async () => {
    // An unset id means the operator wants no rate limiting; client config
    // must keep serving (it gates every app boot).
    process.env.VERCEL = "1";
    delete process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID;
    const fetchMock = mock(async () => new Response(
      JSON.stringify({
        errorsWhileComputingFlags: false,
        featureFlags: {},
        featureFlagPayloads: {},
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    ));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await POST(new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ distinctId: "browser-id" }),
    }));

    expect(response.status).toBe(200);
    expect(checkRateLimit).not.toHaveBeenCalled();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("fails open on Vercel when the client-config limiter rule is not found", async () => {
    // A deleted rule is an operator action (no limit wanted), not an outage.
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "not-found" });
    const fetchMock = mock(async () => new Response(
      JSON.stringify({
        errorsWhileComputingFlags: false,
        featureFlags: {},
        featureFlagPayloads: {},
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    ));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await POST(new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ distinctId: "browser-id" }),
    }));

    expect(response.status).toBe(200);
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledTimes(1);
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
      { failure: "check_error" },
    );
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("rate limits every request while serving complete evaluations from the runtime cache", async () => {
    mutableEnv.NODE_ENV = "production";
    process.env.VERCEL = "1";
    mutableEnv.VERCEL_ENV = "production";
    process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = "cmux-client-config-test";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    const fetchMock = mock(async () => new Response(
      JSON.stringify({
        errorsWhileComputingFlags: false,
        featureFlags: { "runtime-cache-test": true },
        featureFlagPayloads: {},
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    ));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const distinctId = "runtime-cache-test";
    const request = () => new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ distinctId }),
    });

    const first = await POST(request());
    const second = await POST(request());

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(first.headers.get("x-cmux-client-config-cache")).toBe("miss");
    expect(second.headers.get("x-cmux-client-config-cache")).toBe("hit");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(checkRateLimit).toHaveBeenCalledTimes(2);

    checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });
    const blocked = await POST(request());
    expect(blocked.status).toBe(429);
    expect(blocked.headers.get("retry-after")).toBe("60");
    expect(await blocked.json()).toEqual({ error: "rate_limited" });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(checkRateLimit).toHaveBeenCalledTimes(3);
  });

  test("coalesces concurrent cold evaluations for the same install", async () => {
    mutableEnv.NODE_ENV = "production";
    process.env.VERCEL = "1";
    mutableEnv.VERCEL_ENV = "production";
    process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = "cmux-client-config-test";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    let releaseFetch!: () => void;
    const fetchGate = new Promise<void>((resolve) => {
      releaseFetch = resolve;
    });
    const fetchMock = mock(async () => {
      await fetchGate;
      return new Response(
        JSON.stringify({
          errorsWhileComputingFlags: false,
          requestId: "coalesced-request",
          featureFlags: { "coalesced-test": true },
          featureFlagPayloads: {},
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const distinctId = "coalesced-test";
    const request = () => new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ distinctId }),
    });

    const firstPromise = POST(request());
    await new Promise((resolve) => setTimeout(resolve, 0));
    const secondPromise = POST(request());
    await new Promise((resolve) => setTimeout(resolve, 0));

    releaseFetch();
    const [first, second] = await Promise.all([firstPromise, secondPromise]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(checkRateLimit).toHaveBeenCalledTimes(2);
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(first.headers.get("x-cmux-client-config-cache")).toBe("miss");
    expect(second.headers.get("x-cmux-client-config-cache")).toBe("coalesced");
  });

  test("a blocked concurrent caller cannot join another request's evaluation", async () => {
    mutableEnv.NODE_ENV = "production";
    process.env.VERCEL = "1";
    process.env.VERCEL_ENV = "production";
    let releaseFetch!: () => void;
    const gate = new Promise<void>((resolve) => { releaseFetch = resolve; });
    const fetchMock = mock(async () => {
      await gate;
      return Response.json({ errorsWhileComputingFlags: false, featureFlags: {}, featureFlagPayloads: {} });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const request = () => new Request("https://cmux.test/api/client-config", {
      method: "POST",
      body: JSON.stringify({ distinctId: "blocked-concurrent-test" }),
    });

    const allowed = POST(request());
    await new Promise((resolve) => setTimeout(resolve, 0));
    checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });
    const blocked = POST(request());
    await new Promise((resolve) => setTimeout(resolve, 0));
    releaseFetch();
    const [allowedResponse, blockedResponse] = await Promise.all([allowed, blocked]);

    expect(allowedResponse.status).toBe(200);
    expect(blockedResponse.status).toBe(429);
    expect(checkRateLimit).toHaveBeenCalledTimes(2);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test.each([
    { errorsWhileComputingFlags: true },
    { errorsWhileComputingFlags: false, flags: { broken: { enabled: true, failed: true } } },
  ])("does not cache partial evaluations: %j", async (partial) => {
    mutableEnv.NODE_ENV = "production";
    process.env.VERCEL = "1";
    mutableEnv.VERCEL_ENV = "production";
    process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = "cmux-client-config-test";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    const fetchMock = mock(async () => new Response(
      JSON.stringify({
        ...(fetchMock.mock.calls.length === 1 ? partial : { errorsWhileComputingFlags: false }),
        featureFlags: { "partial-cache-test": true },
        featureFlagPayloads: {},
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    ));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const distinctId = "partial-cache-test";
    const request = () => new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ distinctId }),
    });

    const first = await POST(request());
    const second = await POST(request());

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

});

function restoreEnv(key: string, value: string | undefined): void {
  if (typeof value === "undefined") {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}
