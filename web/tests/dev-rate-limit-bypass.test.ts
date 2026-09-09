import { describe, expect, test } from "bun:test";

import {
  DEVELOPMENT_STACK_PROJECT_ID,
  isAuthorizedDevRelayRateLimitBypass,
  isDevelopmentRelayClientNamespace,
  parseDevRelayRateLimitBypassTeamIds,
} from "../services/relay/devRateLimitBypass";

describe("authorized development relay rate-limit bypass", () => {
  test("recognizes only tagged development namespaces", () => {
    expect(isDevelopmentRelayClientNamespace("dev.cmux.ios.grid")).toBe(true);
    expect(isDevelopmentRelayClientNamespace("mac:com.cmuxterm.app.debug.grid")).toBe(true);
    expect(isDevelopmentRelayClientNamespace("dev.cmux.app.beta")).toBe(false);
    expect(isDevelopmentRelayClientNamespace("mac:com.cmuxterm.app")).toBe(false);
    expect(isDevelopmentRelayClientNamespace("legacy")).toBe(false);
  });

  test("parses and normalizes the configured team allowlist", () => {
    expect([...parseDevRelayRateLimitBypassTeamIds(" team-a,TEAM-B ,, team-a ")])
      .toEqual(["team-a", "team-b"]);
    expect(parseDevRelayRateLimitBypassTeamIds(" , ").size).toBe(0);
  });

  test("requires explicit enablement, the dev Stack project, a debug namespace, and membership", () => {
    const base = {
      clientNamespace: "dev.cmux.ios.grid",
      teamIds: ["team-a"],
      env: {
        CMUX_IROH_DEV_RATE_LIMIT_BYPASS_ENABLED: "1",
        CMUX_IROH_DEV_RATE_LIMIT_BYPASS_TEAM_IDS: "team-a,team-b",
        NEXT_PUBLIC_STACK_PROJECT_ID: DEVELOPMENT_STACK_PROJECT_ID,
      },
    };
    expect(isAuthorizedDevRelayRateLimitBypass(base)).toBe(true);
    expect(isAuthorizedDevRelayRateLimitBypass({
      ...base,
      teamIds: ["team-c"],
    })).toBe(false);
    expect(isAuthorizedDevRelayRateLimitBypass({
      ...base,
      clientNamespace: "dev.cmux.app.beta",
    })).toBe(false);
    expect(isAuthorizedDevRelayRateLimitBypass({
      ...base,
      env: {
        ...base.env,
        CMUX_IROH_DEV_RATE_LIMIT_BYPASS_ENABLED: "0",
      },
    })).toBe(false);
    expect(isAuthorizedDevRelayRateLimitBypass({
      ...base,
      env: {
        ...base.env,
        NEXT_PUBLIC_STACK_PROJECT_ID: "production-stack-project",
      },
    })).toBe(false);
  });
});
