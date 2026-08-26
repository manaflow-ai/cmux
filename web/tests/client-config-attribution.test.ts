import { describe, expect, test } from "bun:test";

import {
  CLIENT_CONFIG_APP_BUILD_HEADER,
  CLIENT_CONFIG_APP_VERSION_HEADER,
  CLIENT_CONFIG_CHANNEL_HEADER,
  CLIENT_CONFIG_CLIENT_HEADER,
  CLIENT_CONFIG_POLL_INTERVAL_HEADER,
  CLIENT_CONFIG_REFRESH_REASON_HEADER,
  readClientConfigRequestAttribution,
} from "../services/client-config/requestAttribution";

describe("client config request attribution", () => {
  test("reads labeled requests from the native apps", () => {
    const attribution = readClientConfigRequestAttribution(new Headers({
      [CLIENT_CONFIG_CLIENT_HEADER]: "macos",
      [CLIENT_CONFIG_CHANNEL_HEADER]: "Nightly",
      [CLIENT_CONFIG_REFRESH_REASON_HEADER]: "timer",
      [CLIENT_CONFIG_APP_VERSION_HEADER]: "0.64.22-nightly.202608250",
      [CLIENT_CONFIG_APP_BUILD_HEADER]: "202608250",
      [CLIENT_CONFIG_POLL_INTERVAL_HEADER]: "1800",
    }));

    expect(attribution).toEqual({
      client: "macos",
      channel: "nightly",
      reason: "timer",
      appVersion: "0.64.22-nightly.202608250",
      appBuild: "202608250",
      pollIntervalSeconds: 1800,
    });
  });

  test("labels unlabeled requests as unknown", () => {
    expect(readClientConfigRequestAttribution(new Headers())).toEqual({
      client: "unknown",
      channel: "unknown",
      reason: "unknown",
      appVersion: "unknown",
      appBuild: "unknown",
      pollIntervalSeconds: null,
    });
  });

  test("collapses unrecognized enum values to other instead of logging them", () => {
    const attribution = readClientConfigRequestAttribution(new Headers({
      [CLIENT_CONFIG_CLIENT_HEADER]: "curl/8.5 (something-unrecognized)",
      [CLIENT_CONFIG_CHANNEL_HEADER]: "canary",
      [CLIENT_CONFIG_REFRESH_REASON_HEADER]: "because",
    }));

    expect(attribution.client).toBe("other");
    expect(attribution.channel).toBe("other");
    expect(attribution.reason).toBe("other");
  });

  test("collapses malformed version, build, and interval values", () => {
    const attribution = readClientConfigRequestAttribution(new Headers({
      [CLIENT_CONFIG_APP_VERSION_HEADER]: "0.64 <script>",
      [CLIENT_CONFIG_APP_BUILD_HEADER]: "x".repeat(65),
      [CLIENT_CONFIG_POLL_INTERVAL_HEADER]: "-5",
    }));

    expect(attribution.appVersion).toBe("invalid");
    expect(attribution.appBuild).toBe("invalid");
    expect(attribution.pollIntervalSeconds).toBeNull();

    expect(
      readClientConfigRequestAttribution(new Headers({
        [CLIENT_CONFIG_POLL_INTERVAL_HEADER]: "999999999",
      })).pollIntervalSeconds,
    ).toBeNull();
  });
});
