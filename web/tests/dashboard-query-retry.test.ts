import { describe, expect, test } from "bun:test";
import { ORPCError } from "@orpc/client";
import { isTransientError } from "../dashboard-app/lib/query-client";

function declared(code: string, status: number): ORPCError<string, unknown> {
  return new ORPCError(code, { status, defined: true, data: { reason: code.toLowerCase() } });
}

describe("dashboard query retry policy", () => {
  test("declared 4xx refusals answer the same way every time and are not retried", () => {
    for (const [code, status] of [["UNAUTHORIZED", 401], ["FORBIDDEN", 403], ["NOT_FOUND", 404], ["CONFLICT", 409]] as const) {
      expect({ code, transient: isTransientError(declared(code, status)) }).toEqual({ code, transient: false });
    }
  });

  test("network failures, undeclared server errors, and declared 5xx are retried", () => {
    expect(isTransientError(new TypeError("Failed to fetch"))).toBe(true);
    expect(isTransientError(new ORPCError("INTERNAL_SERVER_ERROR", { status: 500 }))).toBe(true);
    expect(isTransientError(declared("UNAVAILABLE", 503))).toBe(true);
  });
});

describe("dashboard query retry budget", () => {
  test("a transient failure is retried once, about a second later, so the error shows within ~2 s", async () => {
    const { shouldRetryQuery, DASHBOARD_RETRY_DELAY_MS } = await import("../dashboard-app/lib/query-client");
    const outage = declared("UNAVAILABLE", 503);
    expect([shouldRetryQuery(0, outage), shouldRetryQuery(1, outage)]).toEqual([true, false]);
    expect(shouldRetryQuery(0, declared("FORBIDDEN", 403))).toBe(false);
    expect(DASHBOARD_RETRY_DELAY_MS).toBeGreaterThanOrEqual(500);
    expect(DASHBOARD_RETRY_DELAY_MS).toBeLessThanOrEqual(1500);
  });
});
