import { describe, expect, test } from "bun:test";
import { attachTokenHash, hugeBlueRelayConfig } from "../services/vms/hugeBlueAttachTokens";

describe("Huge Blue attach token primitives", () => {
  test("hashes opaque capabilities without retaining the raw token", () => {
    const token = "hba_" + "a".repeat(64);
    expect(attachTokenHash(token)).toBe("fcf5cd73da972438a36906a75ae6fb6795fd248a619bea16427b67cb68ca6fb5");
    expect(attachTokenHash(token)).not.toContain(token);
  });

  test("accepts only credential-free wss link routes and bounded identities", () => {
    const config = hugeBlueRelayConfig({
      HUGE_BLUE_CMUX_REMOTE_URL: "wss://relay.example/v1/link",
      HUGE_BLUE_VM_ID: "huge-blue-staging",
      HUGE_BLUE_CMUX_REMOTE_SESSION: "huge-blue-staging",
      HUGE_BLUE_ATTACH_TTL_MS: "300000",
    });
    expect(config.route.href).toBe("wss://relay.example/v1/link");
    expect(config.hostId).toBe("huge-blue-staging");
    expect(config.session).toBe("huge-blue-staging");
    expect(config.ttlMs).toBe(300000);

    expect(() => hugeBlueRelayConfig({
      HUGE_BLUE_CMUX_REMOTE_URL: "wss://relay.example/v1/link?token=static",
      HUGE_BLUE_VM_ID: "huge-blue-staging",
      HUGE_BLUE_CMUX_REMOTE_SESSION: "huge-blue-staging",
    })).toThrow("credential-free");
    expect(() => hugeBlueRelayConfig({
      HUGE_BLUE_CMUX_REMOTE_URL: "https://relay.example/v1/link",
      HUGE_BLUE_VM_ID: "huge-blue-staging",
      HUGE_BLUE_CMUX_REMOTE_SESSION: "huge-blue-staging",
    })).toThrow("credential-free");
  });
});
