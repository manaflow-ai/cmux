import { describe, expect, test } from "bun:test";
import { isAllowedAnalyticsEvent } from "./iosEventPolicy";

describe("iOS analytics event policy", () => {
  test("accepts terminal freeze diagnostics events", () => {
    for (const event of [
      "ios_terminal_render_stall",
      "ios_terminal_render_stall_recovered",
      "ios_terminal_replay_failed",
      "ios_terminal_replay_retry_exhausted",
      "ios_terminal_viewport_barrier",
      "ios_terminal_liveness_probe",
      "ios_terminal_resync",
      "ios_terminal_manual_recovery",
    ]) {
      expect(isAllowedAnalyticsEvent(event)).toBe(true);
    }
  });

  test("rejects unknown iOS analytics events", () => {
    expect(isAllowedAnalyticsEvent("ios_terminal_freeze_content_dump")).toBe(false);
    expect(isAllowedAnalyticsEvent(null)).toBe(false);
  });
});
