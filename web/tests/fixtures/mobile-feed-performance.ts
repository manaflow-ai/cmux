/** Two callbacks (16ms, 120ms) and one 10ms model application. */
export function feedPerformanceWindow() {
  return {
    event: "ios_feed_performance_window",
    timestamp: "2026-10-08T04:00:00Z",
    properties: {
      platform: "ios", client_channel: "dev", app_version: "0.1.0", build_number: "42",
      bundle_identifier: "dev.cmux.ios.fperf4", os_version: "26.5", device_model: "iPhone",
      build_sha: "a".repeat(40), is_simulator: true, schema_version: 1,
      window_id: "2dcadcc5-4e91-4343-a48e-896889eb1e48", item_count: 400, window_ms: 10_000,
      callback_count: 2, callback_gap_max_ms: 120, scroll_observed_ms: 136,
      callback_gap_histogram: "[0,0,1,0,0,0,0,1,0,0]",
      callback_budget_histogram: "[0,0,2,0,0,0,0,0,0,0]",
      gaps_over_50ms: 1, gaps_over_100ms: 1, updates_while_scrolling: 1,
      fetch_histogram: "[0,0,0,0,0,0,0,0,0,0]", fetch_max_ms: 0,
      decode_histogram: "[0,0,0,0,0,0,0,0,0,0]", decode_max_ms: 0,
      apply_histogram: "[0,1,0,0,0,0,0,0,0,0]", apply_max_ms: 10,
      projection_histogram: "[0,0,0,0,0,0,0,0,0,0]", projection_max_ms: 0,
    },
  };
}
