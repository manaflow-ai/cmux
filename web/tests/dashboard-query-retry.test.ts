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
