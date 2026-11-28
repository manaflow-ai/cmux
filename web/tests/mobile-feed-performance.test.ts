import { describe, expect, test } from "bun:test";

import { mobileFeedPerformanceAttributes, parseMobileFeedPerformanceEvent } from "../services/observability/mobileFeedPerformance";
import { parseMobileObservabilityEvent } from "../services/observability/mobileNetworkOutcome";
import { feedPerformanceWindow } from "./fixtures/mobile-feed-performance";

describe("Feed performance ingestion", () => {
  test("preserves measured distributions, exact build, and client time as attributes", () => {
    const event = parseMobileFeedPerformanceEvent(feedPerformanceWindow());
    expect(event).not.toBeNull();
    if (!event) throw new Error("Expected valid event");
    const attributes = mobileFeedPerformanceAttributes("authenticated-user", event);
    expect(attributes["cmux.user_id"]).toBe("authenticated-user");
    expect(attributes["cmux.mobile.occurred_at"]).toBe("2026-10-08T04:00:00Z");
    expect(attributes["cmux.mobile.feed.build_sha"]).toBe("a".repeat(40));
    expect(attributes["cmux.mobile.feed.callback_gap_histogram"]).toBe("[0,0,1,0,0,0,0,1,0,0]");
    expect(attributes["cmux.mobile.feed.is_simulator"]).toBe(true);
    expect(attributes["cmux.mobile.feed.measurement"]).toBe("display_link_callback_gap");
    expect(parseMobileObservabilityEvent(feedPerformanceWindow())).toEqual(event);
  });

  test.each(["text", "prompt", "url", "workspace_id", "user_id", "stack_trace", "trace_id"])(
    "rejects unexpected %s fields", (key) => {
      const candidate = feedPerformanceWindow();
      Object.assign(candidate.properties, { [key]: "private content" });
      expect(parseMobileObservabilityEvent(candidate)).toBeNull();
    },
  );

  test.each([
    ["callback_count", -1], ["callback_count", 1.5], ["callback_count", 3],
    ["item_count", 10_001], ["callback_gap_max_ms", 60_001],
    ["build_sha", "https://private.example"], ["app_version", "user@example.com"],
    ["schema_version", 2], ["is_simulator", "yes"], ["window_id", "workspace-name"],
    ["gaps_over_50ms", 2], ["gaps_over_100ms", 2], ["updates_while_scrolling", 2],
    ["callback_gap_histogram", "[]"], ["callback_gap_histogram", "[0,0,2,0,0,0,0,0,0,0]"],
    ["callback_budget_histogram", "[0,0,1,0,0,0,0,0,0,0]"],
    ["apply_histogram", "[0,-1,0,0,0,0,0,0,0,0]"],
    ["apply_histogram", "[0,1000001,0,0,0,0,0,0,0,0]"],
    ["projection_histogram", "not-json"],
  ])("rejects invalid or inconsistent %s=%j", (key, value) => {
    const candidate = feedPerformanceWindow();
    Object.assign(candidate.properties, { [key as string]: value });
    expect(parseMobileObservabilityEvent(candidate)).toBeNull();
  });

  test("a stalled window links to Sentry without attaching Feed or account identifiers", () => {
    const event = {
      event: "ios_feed_scroll_anomaly", timestamp: "2026-10-08T04:00:00Z",
      properties: {
        schema_version: 1, is_simulator: false,
        window_id: "2dcadcc5-4e91-4343-a48e-896889eb1e48", item_count: 400,
        callback_count: 600, callback_gap_max_ms: 120, sentry_event_id: "b".repeat(32),
      },
    };
    const accepted = parseMobileFeedPerformanceEvent(event);
    expect(accepted).not.toBeNull();
    if (!accepted) throw new Error("Expected valid anomaly");
    expect(mobileFeedPerformanceAttributes("server-user", accepted)["cmux.mobile.feed.sentry_event_id"]).toBe("b".repeat(32));
    expect(parseMobileFeedPerformanceEvent({ ...event, properties: { ...event.properties, sentry_event_id: "private" } })).toBeNull();
    expect(parseMobileFeedPerformanceEvent({ ...event, properties: { ...event.properties, callback_gap_max_ms: 50 } })).toBeNull();
  });
});
