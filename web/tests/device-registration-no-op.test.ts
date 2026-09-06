import { describe, expect, test } from "bun:test";

import {
  presenceTouchIntervalMs,
  registrationIsUnchanged,
  type StoredRegistration,
} from "../services/devices/registrationNoOp";

const now = new Date("2026-09-03T04:00:00.000Z");

const irohRoute = {
  id: "iroh-primary",
  kind: "iroh",
  endpoint: { type: "peer", id: "a".repeat(64), relay_url: "https://use4.relay.cmux.dev/" },
  priority: 1,
};

function stored(overrides: Partial<StoredRegistration> = {}): StoredRegistration {
  return {
    userId: "user-1",
    platform: "mac",
    displayName: "Lawrence's MacBook",
    labels: { channel: "stable" },
    instanceRoutes: [irohRoute],
    instanceLabels: { tag: "default" },
    lastSeenAt: new Date(now.getTime() - 5_000),
    ...overrides,
  };
}

const incoming = {
  userId: "user-1",
  platform: "mac",
  displayName: "Lawrence's MacBook",
  labels: { channel: "stable" },
  instanceRoutes: [irohRoute],
  instanceLabels: { tag: "default" },
};

function check(
  storedValue: StoredRegistration | null,
  incomingValue = incoming,
  touchIntervalMs = 60_000,
): boolean {
  return registrationIsUnchanged({
    stored: storedValue,
    incoming: incomingValue,
    now,
    touchIntervalMs,
  });
}

describe("device registration no-op detection", () => {
  test("an identical re-registration inside the touch interval writes nothing", () => {
    expect(check(stored())).toBe(true);
  });

  test("object key order does not count as a change", () => {
    const reordered = {
      ...incoming,
      instanceRoutes: [{
        priority: 1,
        kind: "iroh",
        id: "iroh-primary",
        endpoint: { relay_url: "https://use4.relay.cmux.dev/", id: "a".repeat(64), type: "peer" },
      }],
      labels: { channel: "stable" },
    };
    expect(check(stored(), reordered)).toBe(true);
  });

  test("a device registering for the first time is never a no-op", () => {
    expect(check(null)).toBe(false);
  });

  test("a stale presence timestamp forces the write through", () => {
    expect(check(stored({ lastSeenAt: new Date(now.getTime() - 61_000) })).valueOf()).toBe(false);
    // Exactly at the interval still writes: the boundary belongs to freshness.
    expect(check(stored({ lastSeenAt: new Date(now.getTime() - 60_000) }))).toBe(false);
  });

  test("a presence timestamp from the future never looks fresh", () => {
    expect(check(stored({ lastSeenAt: new Date(now.getTime() + 5_000) }))).toBe(false);
  });

  test("any real change falls through to the write path", () => {
    expect(check(stored({ userId: "user-2" }))).toBe(false);
    expect(check(stored({ platform: "ios" }))).toBe(false);
    expect(check(stored({ displayName: null }))).toBe(false);
    expect(check(stored({ labels: { channel: "nightly" } }))).toBe(false);
    expect(check(stored({ instanceLabels: {} }))).toBe(false);
  });

  test("a changed route set is never a no-op", () => {
    expect(check(stored({ instanceRoutes: [] }))).toBe(false);
    expect(check(stored({ instanceRoutes: [irohRoute, irohRoute] }))).toBe(false);
    expect(check(stored({
      instanceRoutes: [{ ...irohRoute, priority: 2 }],
    }))).toBe(false);
    expect(check(stored({
      instanceRoutes: [{
        ...irohRoute,
        endpoint: { ...irohRoute.endpoint, relay_url: "https://usw1.relay.cmux.dev/" },
      }],
    }))).toBe(false);
  });

  test("route order is significant, because priority order is meaningful", () => {
    const second = { ...irohRoute, id: "iroh-secondary", priority: 2 };
    expect(check(
      stored({ instanceRoutes: [irohRoute, second] }),
      { ...incoming, instanceRoutes: [second, irohRoute] },
    )).toBe(false);
  });

  test("a zero interval disables the short-circuit entirely", () => {
    expect(check(stored(), incoming, 0)).toBe(false);
  });
});

describe("presenceTouchIntervalMs", () => {
  test("defaults to one minute", () => {
    expect(presenceTouchIntervalMs(undefined)).toBe(60_000);
    expect(presenceTouchIntervalMs("  ")).toBe(60_000);
  });

  test("honors an override, including zero to disable", () => {
    expect(presenceTouchIntervalMs("15000")).toBe(15_000);
    expect(presenceTouchIntervalMs("0")).toBe(0);
  });

  test("ignores values that are not whole non-negative milliseconds", () => {
    expect(presenceTouchIntervalMs("-1")).toBe(60_000);
    expect(presenceTouchIntervalMs("soon")).toBe(60_000);
  });
});
