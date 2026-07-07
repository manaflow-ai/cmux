import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

const originalFetch = globalThis.fetch;
const originalVercel = process.env.VERCEL;
const originalClientConfigRateLimitId = process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID;

const fetchMock = mock(async () => new Response("ok", { status: 200 }));
const checkRateLimit = mock(async () => ({ rateLimited: false, error: null }));

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

globalThis.fetch = fetchMock as unknown as typeof fetch;

const { POST } = await import("../app/api/analytics/browser-events/route");
const { POSTHOG_PROJECT_KEY } = await import("../services/analytics/browserEventPolicy");

afterAll(() => {
  globalThis.fetch = originalFetch;
  restoreEnv("VERCEL", originalVercel);
  restoreEnv("CMUX_CLIENT_CONFIG_RATE_LIMIT_ID", originalClientConfigRateLimitId);
});

beforeEach(() => {
  process.env.VERCEL = "0";
  process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = "cmux-client-config-test";
  fetchMock.mockClear();
  fetchMock.mockResolvedValue(new Response("ok", { status: 200 }));
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
});

function request(body: unknown): Request {
  return new Request("https://cmux.test/api/analytics/browser-events", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function rawRequest(body: string): Request {
  return new Request("https://cmux.test/api/analytics/browser-events", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });
}

function restoreEnv(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}

describe("browser analytics route", () => {
  test("forwards allowlisted browser events to PostHog from the server", async () => {
    const response = await POST(request({
      event: "cmuxterm_download_clicked",
      distinctId: "visitor-1",
      properties: {
        location: "hero",
        platform: "mac",
        nested: { kept: true },
      },
      timestamp: "2026-07-07T12:00:00.000Z",
    }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const calls = (fetchMock as unknown as {
      mock: { calls: Array<[string | URL | Request, RequestInit?]> };
    }).mock.calls;
    expect(calls[0]?.[0]).toBe("https://r.cmux.com/batch/");
    const body = JSON.parse((calls[0]?.[1]?.body as string) ?? "{}");
    expect(body).toMatchObject({
      api_key: POSTHOG_PROJECT_KEY,
      batch: [
        {
          event: "cmuxterm_download_clicked",
          distinct_id: "visitor-1",
          properties: {
            location: "hero",
            platform: "mac",
            nested: { kept: true },
          },
          timestamp: "2026-07-07T12:00:00.000Z",
        },
      ],
    });
  });

  test("preserves waitlist enrollment properties", async () => {
    const response = await POST(request({
      event: "cmuxterm_waitlist_signup",
      distinctId: "ada@example.com",
      properties: {
        email: "ada@example.com",
        platforms: ["linux", "windows"],
        $set: {
          email: "ada@example.com",
          "$feature_enrollment/cmux-linux-early-access": true,
        },
        $set_once: { waitlist_email: "ada@example.com" },
      },
    }));

    expect(response.status).toBe(200);
    const calls = (fetchMock as unknown as {
      mock: { calls: Array<[string | URL | Request, RequestInit?]> };
    }).mock.calls;
    const body = JSON.parse((calls[0]?.[1]?.body as string) ?? "{}");
    expect(body.batch[0].properties).toEqual({
      email: "ada@example.com",
      platforms: ["linux", "windows"],
      $set: {
        email: "ada@example.com",
        "$feature_enrollment/cmux-linux-early-access": true,
      },
      $set_once: { waitlist_email: "ada@example.com" },
    });
  });

  test("rejects arbitrary event names before forwarding", async () => {
    const response = await POST(request({
      event: "anything_goes",
      distinctId: "visitor-1",
      properties: { location: "hero" },
    }));

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "unknown_event" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("rate-limits Vercel requests before parsing or forwarding", async () => {
    process.env.VERCEL = "1";
    process.env.CMUX_CLIENT_CONFIG_RATE_LIMIT_ID = " cmux-client-config-test\n";
    checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });

    const response = await POST(rawRequest("{"));

    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({ error: "rate_limited" });
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    const calls = (checkRateLimit as unknown as {
      mock: { calls: Array<[string, { request: Request }]> };
    }).mock.calls;
    expect(calls[0]?.[0]).toBe("cmux-client-config-test");
    expect(calls[0]?.[1]?.request.url).toBe("https://cmux.test/api/analytics/browser-events");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
