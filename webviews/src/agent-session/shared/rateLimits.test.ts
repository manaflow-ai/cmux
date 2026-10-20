import { expect, test } from "bun:test";
import {
  activeRateLimitRow,
  formatRateLimitPercent,
  formatRateLimitReset,
  formatRateLimitWindow,
  normalizeRateLimitRow,
} from "./rateLimits";

test("rate limit rows derive used percent from remaining percent", () => {
  expect(normalizeRateLimitRow({ role: "primary", remainingPercent: 42 }).usedPercent).toBe(58);
});

test("active rate limit row prefers the highest used percent", () => {
  const row = activeRateLimitRow([
    { role: "primary", remainingPercent: 40, usedPercent: 60, windowDurationMins: 300 },
    { role: "secondary", remainingPercent: 20, usedPercent: 80, windowDurationMins: 10_080 },
  ]);

  expect(row?.role).toBe("secondary");
  expect(row?.remainingPercent).toBe(20);
});

test("active rate limit row breaks ties by longer reset window", () => {
  const row = activeRateLimitRow([
    { role: "primary", remainingPercent: 25, usedPercent: 75, windowDurationMins: 300 },
    { role: "secondary", remainingPercent: 25, usedPercent: 75, windowDurationMins: 10_080 },
  ]);

  expect(row?.role).toBe("secondary");
});

test("rate limit formatting matches Codex compact labels", () => {
  expect(formatRateLimitPercent(93.4)).toBe("93%");
  expect(formatRateLimitWindow(300, "Primary")).toBe("Primary");
  expect(formatRateLimitWindow(300, "Primary", compactRateLimitLabels())).toBe("5 hours");
  expect(formatRateLimitWindow(60 * 24 * 3, "Primary", compactRateLimitLabels())).toBe("3 days");
  expect(formatRateLimitWindow(10_080, "Secondary", compactRateLimitLabels())).toBe("Weekly");
  expect(formatRateLimitWindow(43_200, "Secondary", compactRateLimitLabels())).toBe("Monthly");
});

test("rate limit resets use time for same-day resets", () => {
  const reset = Date.UTC(2026, 4, 27, 20, 15, 0) / 1000;
  const now = new Date(Date.UTC(2026, 4, 27, 18, 0, 0));

  expect(formatRateLimitReset(reset, now)).toMatch(/8:15|20:15/);
});

function compactRateLimitLabels() {
  return {
    weekly: "Weekly",
    monthly: "Monthly",
    daysFormat: "%@ days",
    hoursFormat: "%@ hours",
    minutesFormat: "%@ minutes",
  };
}
