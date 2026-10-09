import { describe, expect, it } from "bun:test";
import { parseRetryAfterSeconds, rateLimitedJson } from "../src/retryAfterResponse";

describe("rate-limited response", () => {
  it("always carries the authoritative retry deadline", async () => {
    const response = rateLimitedJson({ error: "too_many_subscribers" });
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual({ error: "too_many_subscribers" });
  });

  it("parses both standard Retry-After forms", () => {
    const now = Date.parse("2026-09-08T12:00:00Z");
    expect(parseRetryAfterSeconds("45", now)).toBe(45);
    expect(parseRetryAfterSeconds("Tue, 08 Sep 2026 12:02:00 GMT", now)).toBe(120);
    expect(parseRetryAfterSeconds("invalid", now)).toBeUndefined();
  });
});
