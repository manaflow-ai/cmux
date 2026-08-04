import { describe, expect, it } from "bun:test";
import {
  checkDeviceOwner,
  checkSubscriberAdmission,
  MAX_DIRECTED_SUBSCRIBERS_PER_TEAM,
  MAX_DIRECTED_SUBSCRIBERS_PER_USER,
  MAX_SUBSCRIBERS_PER_TEAM,
  shouldDeliverNudge,
  type NudgeSocketView,
} from "../src/core";
import { MAX_TAG_LENGTH, parseDeviceScope, parseNudge } from "../src/validate";

const DEVICE_ID = "11111111-2222-4333-8444-555555555555";
const OTHER_DEVICE_ID = "99999999-8888-4777-8666-555555555555";

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

// Delivery is the security boundary: an accepted subscription is NOT a grant.
// Ownership is re-checked per frame against the CURRENT pin, so these tests
// drive the exact decision the DO's nudge() loop runs per socket.
describe("shouldDeliverNudge", () => {
  const NOW = 1_800_000_000_000;
  const owner = "user-owner";
  const ownerSocket: NudgeSocketView = {
    deviceScope: DEVICE_ID,
    userId: owner,
    expiresAt: NOW + 60_000,
  };

  it("delivers only to an unexpired socket scoped to the device and owned by the pinned user", () => {
    expect(shouldDeliverNudge(ownerSocket, DEVICE_ID, owner, NOW)).toBe(true);
  });

  it("never delivers to a normal presence/sync subscriber", () => {
    expect(
      shouldDeliverNudge({ ...ownerSocket, deviceScope: null }, DEVICE_ID, owner, NOW),
    ).toBe(false);
  });

  it("never delivers to a socket scoped to a different device", () => {
    expect(
      shouldDeliverNudge({ ...ownerSocket, deviceScope: OTHER_DEVICE_ID }, DEVICE_ID, owner, NOW),
    ).toBe(false);
  });

  it("excludes a subscriber who lost the first-heartbeat pin race", () => {
    // The subscribe gate admits a scoped socket for an UNPINNED device (the
    // Mac subscribes at startup, before its first heartbeat pins it)...
    const early = checkDeviceOwner(undefined, "user-competitor");
    expect(early).toEqual({ ok: true, pin: true });
    // ...but the pin is only written by a heartbeat, and the owner won it.
    // The competitor's still-open socket must not receive owner-only frames.
    expect(
      shouldDeliverNudge(
        { ...ownerSocket, userId: "user-competitor" },
        DEVICE_ID,
        owner,
        NOW,
      ),
    ).toBe(false);
  });

  it("excludes a legacy socket that carries no verified user id", () => {
    expect(
      shouldDeliverNudge({ ...ownerSocket, userId: null }, DEVICE_ID, owner, NOW),
    ).toBe(false);
  });

  it("excludes a socket past its token-derived stream deadline", () => {
    expect(
      shouldDeliverNudge({ ...ownerSocket, expiresAt: NOW }, DEVICE_ID, owner, NOW),
    ).toBe(false);
  });

  it("picks exactly the owner's directed socket out of a mixed subscriber set", () => {
    const sockets: NudgeSocketView[] = [
      { deviceScope: null, userId: owner, expiresAt: NOW + 60_000 }, // team presence subscriber
      { deviceScope: OTHER_DEVICE_ID, userId: owner, expiresAt: NOW + 60_000 }, // owner's other Mac
      { deviceScope: DEVICE_ID, userId: "user-competitor", expiresAt: NOW + 60_000 }, // lost pin race
      { deviceScope: DEVICE_ID, userId: null, expiresAt: NOW + 60_000 }, // legacy, no user id
      { deviceScope: DEVICE_ID, userId: owner, expiresAt: NOW - 1 }, // expired
      ownerSocket,
    ];
    const delivered = sockets.filter((socket) =>
      shouldDeliverNudge(socket, DEVICE_ID, owner, NOW),
    );
    expect(delivered).toEqual([ownerSocket]);
  });
});

// Directed sockets draw from their own pool: a fleet of Macs (one directed
// socket per enabled instance) must never 429 the phones' presence streams,
// a full presence pool must not block a Mac's wake-up channel, and one member
// (who may subscribe to UNPINNED device ids) must not be able to park sockets
// until co-members' channels 429.
describe("checkSubscriberAdmission", () => {
  const empty = { directedCount: 0, userDirectedCount: 0, presenceCount: 0 };

  it("admits each kind while its own pool has room", () => {
    expect(checkSubscriberAdmission({ directed: true, ...empty })).toEqual({ ok: true });
    expect(checkSubscriberAdmission({ directed: false, ...empty })).toEqual({ ok: true });
  });

  it("a full directed pool rejects directed sockets but not presence subscribers", () => {
    const directedFull = {
      ...empty,
      directedCount: MAX_DIRECTED_SUBSCRIBERS_PER_TEAM,
    };
    expect(checkSubscriberAdmission({ directed: true, ...directedFull })).toEqual({
      ok: false,
      error: "too_many_subscribers",
    });
    expect(checkSubscriberAdmission({ directed: false, ...directedFull })).toEqual({
      ok: true,
    });
  });

  it("a full presence pool rejects presence subscribers but not directed sockets", () => {
    const presenceFull = {
      ...empty,
      presenceCount: MAX_SUBSCRIBERS_PER_TEAM,
    };
    expect(checkSubscriberAdmission({ directed: false, ...presenceFull })).toEqual({
      ok: false,
      error: "too_many_subscribers",
    });
    expect(checkSubscriberAdmission({ directed: true, ...presenceFull })).toEqual({
      ok: true,
    });
  });

  it("caps one user's directed sockets while the team pool still has room", () => {
    const userAtCap = {
      ...empty,
      directedCount: MAX_DIRECTED_SUBSCRIBERS_PER_USER,
      userDirectedCount: MAX_DIRECTED_SUBSCRIBERS_PER_USER,
    };
    expect(checkSubscriberAdmission({ directed: true, ...userAtCap })).toEqual({
      ok: false,
      error: "too_many_subscribers",
    });
    // A different member (zero directed sockets of their own) is unaffected.
    expect(
      checkSubscriberAdmission({ directed: true, ...userAtCap, userDirectedCount: 0 }),
    ).toEqual({ ok: true });
  });

  it("one user at cap can never fill the team pool", () => {
    expect(MAX_DIRECTED_SUBSCRIBERS_PER_USER).toBeLessThan(MAX_DIRECTED_SUBSCRIBERS_PER_TEAM);
  });
});
