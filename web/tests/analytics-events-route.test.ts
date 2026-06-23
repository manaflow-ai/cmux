import { afterAll, describe, expect, mock, test } from "bun:test";

// Anonymous-first analytics ingest proxy. These tests cover the request shape
// gate (batch/event bounds + allowlist) without touching @vercel/firewall or
// PostHog, so they do not mock any module that sibling test files also mock.

const envKeys = ["SKIP_ENV_VALIDATION"] as const;
const originalEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]])) as Record<
  (typeof envKeys)[number],
  string | undefined
>;

process.env.SKIP_ENV_VALIDATION = "1";

const getUser = mock(async () => null);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
}));

const analyticsRoute = await import("../app/api/analytics/events/route");

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

function post(body: unknown): Promise<Response> {
  return analyticsRoute.POST(
    new Request("https://cmux.test/api/analytics/events", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
  );
}

describe("analytics events route shape gate", () => {
  test("rejects a missing batch with 400", async () => {
    const response = await post({ notBatch: true });
    expect(response.status).toBe(400);
    expect(((await response.json()) as { error: string }).error).toBe("missing_batch");
  });

  test("accepts an empty batch as a no-op forward", async () => {
    const response = await post({ batch: [] });
    expect(response.status).toBe(200);
    expect(((await response.json()) as { ok: boolean; forwarded: number })).toEqual({
      ok: true,
      forwarded: 0,
    });
  });
});
