import { describe, expect, test } from "bun:test";

import { isAllowedAnalyticsEvent } from "../services/analytics/iosEventPolicy";

describe("iOS analytics event allowlist", () => {
  test("rejects the removed high-volume / vague events", () => {
    // `ios_terminal_input_submitted` fired on every submit (highest-volume,
    // pure product-analytics noise) and `ios_event` was a placeholder name with
    // no meaning. Neither should be forwarded to PostHog anymore.
    expect(isAllowedAnalyticsEvent("ios_terminal_input_submitted")).toBe(false);
    expect(isAllowedAnalyticsEvent("ios_event")).toBe(false);
  });

  test("allows the new iOS retention pings", () => {
    // Mirror macOS `cmux_daily_active` / `cmux_hourly_active` so iOS DAU +
    // hourly retention line up symmetrically.
    expect(isAllowedAnalyticsEvent("ios_daily_active")).toBe(true);
    expect(isAllowedAnalyticsEvent("ios_hourly_active")).toBe(true);
  });

  test("keeps the rare dropped-input signal and other real events", () => {
    expect(isAllowedAnalyticsEvent("ios_terminal_input_dropped")).toBe(true);
    expect(isAllowedAnalyticsEvent("ios_app_foregrounded")).toBe(true);
    expect(isAllowedAnalyticsEvent("ios_sign_in_completed")).toBe(true);
    expect(isAllowedAnalyticsEvent("$identify")).toBe(true);
  });

  test("rejects non-string and unknown event names", () => {
    expect(isAllowedAnalyticsEvent("totally_made_up_event")).toBe(false);
    expect(isAllowedAnalyticsEvent(undefined)).toBe(false);
    expect(isAllowedAnalyticsEvent(123)).toBe(false);
  });
});
