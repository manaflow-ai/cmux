import { describe, expect, test } from "bun:test";
import { ORPCError } from "@orpc/client";
import { refusalMessageKind } from "../dashboard-app/lib/refusal-message";

function declared(code: string, status: number): ORPCError<string, unknown> {
  return new ORPCError(code, { status, defined: true, data: { reason: code.toLowerCase() } });
}

describe("refusal message", () => {
  test("each failure maps to one sentence kind", () => {
    const cases: [unknown, string][] = [
      [new TypeError("Failed to fetch"), "network"],
      [new DOMException("The operation timed out.", "TimeoutError"), "network"],
      [declared("UNAVAILABLE", 503), "unavailable"],
      [declared("BAD_GATEWAY", 502), "unavailable"],
      [new ORPCError("INTERNAL_SERVER_ERROR", { status: 500 }), "unavailable"],
      [declared("FORBIDDEN", 403), "forbidden"],
      [declared("NOT_FOUND", 404), "notFound"],
      [declared("GONE", 410), "notFound"],
      [declared("RATE_LIMITED", 429), "rateLimited"],
      [declared("CONFLICT", 409), "generic"],
      [new Error("render bug"), "generic"],
    ];
    expect(cases.map(([error, kind]) => [kind, refusalMessageKind(error)])).toEqual(cases.map(([, kind]) => [kind, kind]));
  });
});
