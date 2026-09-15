import { afterEach, describe, expect, mock, test } from "bun:test";
import { createHash } from "node:crypto";

import { checkAbortableRateLimit } from "../services/client-config/abortableRateLimit";

const originalFetch = globalThis.fetch;
const originalAutomationBypass = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;
const originalRateLimitSecret = process.env.RATE_LIMIT_SECRET;

afterEach(() => {
  globalThis.fetch = originalFetch;
  restoreEnv("VERCEL_AUTOMATION_BYPASS_SECRET", originalAutomationBypass);
  restoreEnv("RATE_LIMIT_SECRET", originalRateLimitSecret);
});

describe("abortable Vercel rate limit", () => {
  test("matches the Firewall protocol and forwards request context", async () => {
    process.env.VERCEL_AUTOMATION_BYPASS_SECRET = "automation-secret";
    process.env.RATE_LIMIT_SECRET = "rate-limit-secret";
    const fetchMock = mock(async () => new Response(null, { status: 204 }));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    const request = new Request("https://preview.cmux.test/api/client-config", {
      headers: {
        host: "preview.cmux.test",
        cookie: "session=keep; _vercel_jwt=jwt-token",
        "x-forwarded-for": "203.0.113.10",
        "x-real-ip": "203.0.113.10",
        "x-request-id": "request-1",
      },
    });

    await expect(checkAbortableRateLimit("client-config", request, "production:install")).resolves.toEqual({
      rateLimited: false,
    });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://preview.cmux.test/.well-known/vercel/rate-limit-api/client-config");
    const headers = new Headers(init.headers);
    const expectedHash = createHash("sha256")
      .update("production:installclient-configautomation-secretrate-limit-secret")
      .digest("hex");
    expect(headers.get("x-vercel-rate-limit-key")).toBe(`production:install-${expectedHash}`);
    expect(headers.get("cookie")).toBe("_vercel_jwt=jwt-token");
    expect(headers.get("x-rr-x-request-id")).toBe("request-1");
    expect(init.signal).toBeInstanceOf(AbortSignal);
  });

  test.each([
    [429, { rateLimited: true }],
    [403, { rateLimited: true, error: "blocked" }],
    [404, { rateLimited: false, error: "not-found" }],
  ] as const)("maps Firewall status %d", async (status, expected) => {
    globalThis.fetch = mock(async () => new Response(null, { status })) as unknown as typeof fetch;
    await expect(checkAbortableRateLimit("client-config", new Request("https://cmux.test/api", {
      headers: { host: "cmux.test" },
    }), "key"))
      .resolves.toEqual(expected);
  });
});

function restoreEnv(key: string, value: string | undefined): void {
  if (typeof value === "undefined") delete process.env[key];
  else process.env[key] = value;
}
