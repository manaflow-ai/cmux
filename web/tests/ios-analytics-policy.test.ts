import { describe, expect, test } from "bun:test";

import { isAllowedAnalyticsEvent } from "../services/analytics/iosEventPolicy";

describe("iOS billing recovery analytics", () => {
  test("allows recovery attempt and failure events through the proxy", () => {
    expect(isAllowedAnalyticsEvent("ios_billing_recovery_attempted")).toBe(true);
    expect(isAllowedAnalyticsEvent("ios_billing_recovery_failed")).toBe(true);
  });
});
