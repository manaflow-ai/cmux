import { describe, expect, it } from "bun:test";
import { parseHeartbeat } from "../src/validate";

const DEVICE_ID = "11111111-2222-4333-8444-555555555555";

describe("parseHeartbeat", () => {
  it("accepts a minimal valid heartbeat and defaults the tag", () => {
    const result = parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac" });
    expect(result).toEqual({
      ok: true,
      beat: {
        deviceId: DEVICE_ID,
        tag: "default",
        platform: "mac",
        displayName: undefined,
        capabilities: undefined,
        stopping: undefined,
      },
    });
  });

  it("lowercases the device id and platform", () => {
    const result = parseHeartbeat({ deviceId: DEVICE_ID.toUpperCase(), platform: "MAC" });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.beat.deviceId).toBe(DEVICE_ID);
      expect(result.beat.platform).toBe("mac");
    }
  });

  it("rejects a non-UUID device id", () => {
    expect(parseHeartbeat({ deviceId: "mac-1", platform: "mac" })).toEqual({
      ok: false,
      error: "invalid_device_id",
    });
  });

  it("rejects unknown platforms", () => {
    expect(parseHeartbeat({ deviceId: DEVICE_ID, platform: "amiga" })).toEqual({
      ok: false,
      error: "invalid_platform",
    });
  });

  it("rejects oversized tags", () => {
    expect(parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac", tag: "x".repeat(65) })).toEqual({
      ok: false,
      error: "invalid_tag",
    });
  });

  it("rejects non-string capabilities and oversized capability lists", () => {
    expect(
      parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac", capabilities: [42] }),
    ).toEqual({ ok: false, error: "invalid_capabilities" });
    expect(
      parseHeartbeat({
        deviceId: DEVICE_ID,
        platform: "mac",
        capabilities: Array.from({ length: 33 }, (_, i) => `cap-${i}`),
      }),
    ).toEqual({ ok: false, error: "invalid_capabilities" });
  });

  it("treats only literal true as stopping", () => {
    const result = parseHeartbeat({ deviceId: DEVICE_ID, platform: "mac", stopping: "yes" });
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.beat.stopping).toBeUndefined();
  });
});
