import { describe, expect, it } from "vitest";
import { browserClientName } from "../src/lib/clientName";

describe("browserClientName", () => {
  it("prefers the user-agent platform and normalizes it", () => {
    expect(browserClientName({
      userAgentData: { platform: "  macOS   desktop  " },
      platform: "MacIntel",
      userAgent: "fallback",
    })).toBe("macOS desktop");
  });

  it("falls back to a trimmed user agent and clamps to 64 characters", () => {
    expect(browserClientName({ userAgent: `  ${"x".repeat(80)}  ` })).toBe("x".repeat(64));
  });
});
