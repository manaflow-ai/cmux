import { describe, expect, test } from "bun:test";

import {
  normalizeOrigin,
  parseArgs,
  parseServerTiming,
  summarize,
} from "../scripts/coderouter/benchmark";

describe("coderouter benchmark harness", () => {
  test("parses quoted Server-Timing descriptions containing commas", () => {
    expect(parseServerTiming(
      'cache;desc="edge, cache";dur=12.5, db;dur=4',
    )).toEqual({ cache: 12.5, db: 4 });
  });

  test("rejects unsupported and duplicate options", () => {
    expect(() => parseArgs(["--orign", "https://example.com"])).toThrow();
    expect(() => parseArgs(["--samples", "1", "--samples=2"])).toThrow();
    const secret = "crt_must_not_be_printed";
    expect(() => parseArgs([secret])).toThrow("Unexpected benchmark argument.");
    try {
      parseArgs([secret]);
    } catch (error) {
      expect(String(error)).not.toContain(secret);
    }
  });

  test("normalizes safe origins and rejects credential-bearing origins", () => {
    expect(normalizeOrigin("https://coderouter.dev/")).toBe(
      "https://coderouter.dev",
    );
    expect(normalizeOrigin("http://localhost:3000")).toBe(
      "http://localhost:3000",
    );
    expect(() => normalizeOrigin("https://token@example.com")).toThrow();
    expect(() => normalizeOrigin("https://example.com/?token=secret")).toThrow();
  });

  test("aggregates status and timing samples without changing output", () => {
    expect(summarize("status", "https://example.com", [
      {
        durationMs: 10,
        status: 200,
        serverTiming: { auth: 2 },
      },
      {
        durationMs: 20,
        status: 503,
        serverTiming: { auth: 4, db: 3 },
      },
    ])).toMatchObject({
      samples: 2,
      successful: 1,
      statusCounts: { "200": 1, "503": 1 },
      latencyMs: { p50: 10, p95: 20 },
      serverTimingMs: {
        auth: { p50: 2, p95: 4 },
        db: { p50: 3, p95: 3 },
      },
    });
  });
});
