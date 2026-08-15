import { describe, expect, mock, test } from "bun:test";

mock.module("posthog-js", () => ({
  default: {},
}));

const {
  booleanClientConfigFlag,
  clientConfigFlags,
  getClientConfigValue,
  payloadClientConfigFlag,
  rawClientConfigFlagValue,
  variantClientConfigFlag,
} = await import("../app/lib/client-config-flags");

import type { ClientConfig } from "../app/lib/client-config";

describe("client-config typed flags", () => {
  test("reads declared boolean flags with safe fallback on wrong type", () => {
    const config: ClientConfig = {
      featureFlags: {
        "cmux-for-windows": true,
        "cmux-for-linux": "beta",
      },
      featureFlagPayloads: {},
      errorsWhileComputingFlags: false,
    };

    expect(getClientConfigValue(config, clientConfigFlags.cmuxForWindows)).toBe(true);
    expect(getClientConfigValue(config, clientConfigFlags.cmuxForLinux)).toBe(false);
    expect(getClientConfigValue(config, booleanClientConfigFlag("missing", true))).toBe(true);
  });

  test("reads declared variant flags with safe fallback on wrong type", () => {
    const config: ClientConfig = {
      featureFlags: {
        "pricing-copy": "enterprise",
        "pricing-enabled": true,
      },
      featureFlagPayloads: {},
      errorsWhileComputingFlags: false,
    };

    expect(getClientConfigValue(config, variantClientConfigFlag("pricing-copy"))).toBe("enterprise");
    expect(getClientConfigValue(config, variantClientConfigFlag("pricing-enabled"))).toBeUndefined();
    expect(getClientConfigValue(config, variantClientConfigFlag("missing", "control"))).toBe("control");
  });

  test("decodes payloads through caller-provided parser", () => {
    const config: ClientConfig = {
      featureFlags: {},
      featureFlagPayloads: {
        "pricing-copy": { headline: "Ship faster", seats: 12 },
      },
      errorsWhileComputingFlags: false,
    };
    const pricingPayload = payloadClientConfigFlag("pricing-copy", (payload) => {
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) return undefined;
      const record = payload as Record<string, unknown>;
      if (typeof record.headline !== "string" || typeof record.seats !== "number") return undefined;
      return { headline: record.headline, seats: record.seats };
    });

    expect(pricingPayload.read(config)).toEqual({ headline: "Ship faster", seats: 12 });
  });

  test("preserves explicit null payloads when a default exists", () => {
    const config: ClientConfig = {
      featureFlags: {},
      featureFlagPayloads: {
        "pricing-copy": null,
      },
      errorsWhileComputingFlags: false,
    };
    const nullablePayload = payloadClientConfigFlag(
      "pricing-copy",
      (payload): string | null | undefined => payload === null ? null : undefined,
      "control",
    );

    expect(nullablePayload.read(config)).toBeNull();
  });

  test("keeps raw access explicitly named for diagnostics", () => {
    const config: ClientConfig = {
      featureFlags: { "unknown-flag": "variant" },
      featureFlagPayloads: {},
      errorsWhileComputingFlags: false,
    };

    expect(rawClientConfigFlagValue(config, "unknown-flag")).toBe("variant");
  });
});
