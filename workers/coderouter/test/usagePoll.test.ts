import { describe, expect, test } from "bun:test";
import {
  ACTIVE_POLL_INTERVAL_MS,
  IDLE_POLL_INTERVAL_MS,
  nextUsagePollAt,
  normalizeAnthropicUsage,
  normalizeOpenAiUsage,
  shouldPollCredential,
  usagePollIntervalMs,
  zeroHeadroomUsageWindows,
} from "../src/usagePoll";

describe("usage poll normalization", () => {
  test("normalizes openai windows", () => {
    expect(
      normalizeOpenAiUsage({
        rate_limit: {
          primary_window: { used_percent: 25, limit_window_seconds: 3600, reset_after_seconds: 120 },
          secondary_window: { used_percent: 50, limit_window_seconds: 86400, reset_after_seconds: 240 },
        },
      }),
    ).toEqual([
      { name: "primary_window", usedPercent: 25, limitWindowSeconds: 3600, resetAfterSeconds: 120 },
      { name: "secondary_window", usedPercent: 50, limitWindowSeconds: 86400, resetAfterSeconds: 240 },
    ]);
  });

  test("normalizes anthropic windows", () => {
    const now = Date.parse("2026-01-01T00:00:00Z");
    expect(
      normalizeAnthropicUsage(
        {
          five_hour: { utilization: 10, resets_at: "2026-01-01T01:00:00Z" },
          seven_day: { utilization: 20, resets_at: "2026-01-02T00:00:00Z" },
        },
        now,
      ),
    ).toEqual([
      { name: "five_hour", usedPercent: 10, limitWindowSeconds: 18000, resetAfterSeconds: 3600 },
      { name: "seven_day", usedPercent: 20, limitWindowSeconds: 604800, resetAfterSeconds: 86400 },
    ]);
  });

  test("uses active and idle per-credential poll cadence", () => {
    const now = 1_000_000;
    expect(usagePollIntervalMs(now, now - 9 * 60 * 1000)).toBe(ACTIVE_POLL_INTERVAL_MS);
    expect(usagePollIntervalMs(now, now - 11 * 60 * 1000)).toBe(IDLE_POLL_INTERVAL_MS);
    expect(shouldPollCredential({ now, lastTrafficAt: now, lastPolledAt: now - ACTIVE_POLL_INTERVAL_MS })).toBe(true);
    expect(shouldPollCredential({ now, lastTrafficAt: now, lastPolledAt: now - ACTIVE_POLL_INTERVAL_MS + 1 })).toBe(false);
    expect(shouldPollCredential({ now, lastTrafficAt: 0, lastPolledAt: now - IDLE_POLL_INTERVAL_MS })).toBe(true);
    expect(nextUsagePollAt({ now, lastTrafficAt: 0, lastPolledAt: now - 1000 })).toBe(now - 1000 + IDLE_POLL_INTERVAL_MS);
  });

  test("auth-like poll failures map to temporary zero-headroom windows", () => {
    expect(zeroHeadroomUsageWindows("anthropic")).toEqual([
      { name: "usage_poll_auth", usedPercent: 100, limitWindowSeconds: 900, resetAfterSeconds: 900 },
    ]);
  });
});
