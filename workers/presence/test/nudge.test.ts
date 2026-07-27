import { describe, expect, it } from "bun:test";
import { MAX_TAG_LENGTH, parseDeviceScope, parseNudge } from "../src/validate";

const DEVICE_ID = "11111111-2222-4333-8444-555555555555";

describe("parseNudge", () => {
  it("accepts a device-wide iroh-binding-changed nudge", () => {
    const parsed = parseNudge({ deviceId: DEVICE_ID, kind: "iroh-binding-changed" });
    expect(parsed).toEqual({
      ok: true,
      nudge: { deviceId: DEVICE_ID, tag: undefined, kind: "iroh-binding-changed" },
    });
  });

  it("normalizes the device id and keeps a bounded tag", () => {
    const parsed = parseNudge({
      deviceId: ` ${DEVICE_ID.toUpperCase()} `,
      tag: " rekey ",
      kind: "iroh-binding-changed",
    });
    expect(parsed).toEqual({
      ok: true,
      nudge: { deviceId: DEVICE_ID, tag: "rekey", kind: "iroh-binding-changed" },
    });
  });

  it("rejects a malformed device id", () => {
    expect(parseNudge({ deviceId: "not-a-uuid", kind: "iroh-binding-changed" })).toEqual({
      ok: false,
      error: "invalid_device_id",
    });
  });

  it("rejects a kind outside the allowlist", () => {
    expect(parseNudge({ deviceId: DEVICE_ID, kind: "drop-all-tables" })).toEqual({
      ok: false,
      error: "invalid_kind",
    });
    expect(parseNudge({ deviceId: DEVICE_ID })).toEqual({
      ok: false,
      error: "invalid_kind",
    });
  });

  it("rejects an over-long tag", () => {
    const parsed = parseNudge({
      deviceId: DEVICE_ID,
      tag: "x".repeat(MAX_TAG_LENGTH + 1),
      kind: "iroh-binding-changed",
    });
    expect(parsed).toEqual({ ok: false, error: "invalid_tag" });
  });
});

describe("parseDeviceScope", () => {
  it("treats an absent or empty parameter as a normal subscribe", () => {
    expect(parseDeviceScope(null)).toEqual({ scope: "none" });
    expect(parseDeviceScope("  ")).toEqual({ scope: "none" });
  });

  it("accepts and normalizes a device UUID", () => {
    expect(parseDeviceScope(DEVICE_ID.toUpperCase())).toEqual({
      scope: "device",
      deviceId: DEVICE_ID,
    });
  });

  it("flags a malformed value so the subscribe can 400 instead of silently downgrading", () => {
    expect(parseDeviceScope("mac-1")).toEqual({ scope: "invalid" });
  });
});
