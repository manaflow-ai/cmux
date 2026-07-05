import { describe, expect, test } from "bun:test";
import { applyLimitHeaders, cooldownAfter429, mergeReportedLimitState, parseRetryAfterSeconds, parseWindows } from "../src/limits";
import { shouldPollCredential } from "../src/usagePoll";

describe("limits", () => {
  test("parses provider windows", () => {
    const anthropic = parseWindows(
      "anthropic",
      {
        "anthropic-ratelimit-requests-remaining": "20",
        "anthropic-ratelimit-requests-limit": "100",
        "anthropic-ratelimit-requests-reset": "60",
      },
      Date.now(),
    );
    expect(anthropic[0]?.usedPercent).toBe(80);
    expect(anthropic[0]?.resetAfterSeconds).toBe(60);

    const openai = parseWindows(
      "openai",
      {
        "x-ratelimit-remaining-requests": "5",
        "x-ratelimit-limit-requests": "10",
        "x-ratelimit-reset-requests": "2m",
      },
      Date.now(),
    );
    expect(openai[0]).toMatchObject({ name: "requests", usedPercent: 50, resetAfterSeconds: 120 });
  });

  test("applies retry-after and exponential cooldown", () => {
    expect(parseRetryAfterSeconds("12")).toBe(12);
    expect(cooldownAfter429(1000, null, 0)).toEqual({ cooldownUntil: 61_000, consecutive429: 1 });
    expect(cooldownAfter429(1000, null, 2)).toEqual({ cooldownUntil: 241_000, consecutive429: 3 });
    const update = applyLimitHeaders({
      family: "openai",
      endpointClass: "openai_api",
      credentialClass: "byok",
      status: 429,
      headers: { "retry-after": "7" },
      now: 1000,
    });
    expect(update.cooldownUntil).toBe(8000);
  });

  test("marks oauth reauth on second 401", () => {
    const update = applyLimitHeaders({
      family: "anthropic",
      endpointClass: "anthropic",
      credentialClass: "oauth",
      status: 401,
      headers: {},
      now: 1000,
      previousConsecutive401: 1,
    });
    expect(update.needsReauth).toBe(true);
    expect(update.cooldownUntil).toBe(301000);
  });

  test("does not replace oauth poll windows from response headers but still applies 429 cooldown", () => {
    const update = applyLimitHeaders({
      family: "anthropic",
      endpointClass: "anthropic",
      credentialClass: "oauth",
      status: 429,
      headers: {
        "anthropic-ratelimit-requests-remaining": "0",
        "anthropic-ratelimit-requests-limit": "100",
        "retry-after": "9",
      },
      now: 1000,
    });
    expect(update.windows).toEqual([]);
    expect(update.cooldownUntil).toBe(10_000);
    expect(update.consecutive429).toBe(1);
  });

  test("reported requests preserve last poll time for oauth cadence", () => {
    const now = 1_000_000;
    const previous = {
      windows: [{ name: "primary_window", usedPercent: 25, limitWindowSeconds: 3600, resetAfterSeconds: 120 }],
      lastPolledAt: now - 60_000,
      consecutive429: 0,
      consecutive401: 0,
      needsReauth: false,
    };
    const update = applyLimitHeaders({
      family: "openai",
      endpointClass: "codex",
      credentialClass: "oauth",
      status: 200,
      headers: {},
      now,
      previousConsecutive429: previous.consecutive429,
      previousConsecutive401: previous.consecutive401,
    });
    const merged = mergeReportedLimitState(previous, update);
    expect(merged.lastPolledAt).toBe(previous.lastPolledAt);
    expect(shouldPollCredential({ now, lastTrafficAt: now, lastPolledAt: merged.lastPolledAt })).toBe(false);
  });
});
