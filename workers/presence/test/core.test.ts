import { describe, expect, it } from "bun:test";
import {
  applyHeartbeat,
  buildSnapshot,
  checkDeviceOwner,
  checkPresenceCaps,
  expireInstances,
  HEARTBEAT_INTERVAL_MS,
  MAX_DEVICES_PER_TEAM,
  MAX_INSTANCES_PER_DEVICE,
  nextAlarmTime,
  OFFLINE_TIMEOUT_MS,
  PRUNE_AFTER_MS,
  resolveSubscribeDeadline,
  routesEqual,
  shouldPrune,
  type HeartbeatInput,
  type PresenceInstance,
} from "../src/core";

const T0 = 1_750_000_000_000;

function beat(overrides: Partial<HeartbeatInput> = {}): HeartbeatInput {
  return {
    deviceId: "11111111-2222-4333-8444-555555555555",
    tag: "default",
    platform: "mac",
    ...overrides,
  };
}

function onlineInstance(overrides: Partial<PresenceInstance> = {}): PresenceInstance {
  return {
    deviceId: "11111111-2222-4333-8444-555555555555",
    tag: "default",
    platform: "mac",
    capabilities: [],
    online: true,
    lastSeenAt: T0,
    onlineSince: T0,
    ...overrides,
  };
}

describe("cadence constants", () => {
  it("offline timeout tolerates two missed heartbeats before declaring offline", () => {
    expect(OFFLINE_TIMEOUT_MS).toBe(3 * HEARTBEAT_INTERVAL_MS);
  });
});

describe("applyHeartbeat", () => {
  it("first heartbeat brings an unknown instance online and emits online", () => {
    const { instance, events } = applyHeartbeat(undefined, beat({ displayName: "Studio" }), T0);
    expect(instance.online).toBe(true);
    expect(instance.onlineSince).toBe(T0);
    expect(instance.lastSeenAt).toBe(T0);
    expect(instance.displayName).toBe("Studio");
    expect(events).toEqual([{ type: "online", instance }]);
  });

  it("repeat heartbeat on an online instance keeps onlineSince and emits only seen", () => {
    const first = applyHeartbeat(undefined, beat(), T0).instance;
    const { instance, events } = applyHeartbeat(first, beat(), T0 + HEARTBEAT_INTERVAL_MS);
    expect(instance.online).toBe(true);
    expect(instance.onlineSince).toBe(T0);
    expect(instance.lastSeenAt).toBe(T0 + HEARTBEAT_INTERVAL_MS);
    expect(events).toEqual([
      {
        type: "seen",
        deviceId: instance.deviceId,
        tag: instance.tag,
        lastSeenAt: T0 + HEARTBEAT_INTERVAL_MS,
      },
    ]);
  });

  it("heartbeat after a timeout-offline re-emits online with a fresh onlineSince", () => {
    const first = applyHeartbeat(undefined, beat(), T0).instance;
    const { expired } = expireInstances([first], T0 + OFFLINE_TIMEOUT_MS);
    const offline = expired[0]!;
    const later = T0 + OFFLINE_TIMEOUT_MS + 5_000;
    const { instance, events } = applyHeartbeat(offline, beat(), later);
    expect(instance.online).toBe(true);
    expect(instance.onlineSince).toBe(later);
    expect(events[0]!.type).toBe("online");
  });

  it("preserves displayName and capabilities from the previous record when omitted", () => {
    const first = applyHeartbeat(
      undefined,
      beat({ displayName: "Studio", capabilities: ["terminal"] }),
      T0,
    ).instance;
    const { instance } = applyHeartbeat(first, beat(), T0 + 1);
    expect(instance.displayName).toBe("Studio");
    expect(instance.capabilities).toEqual(["terminal"]);
  });

  it("goodbye on an online instance flips offline immediately with reason goodbye", () => {
    const first = applyHeartbeat(undefined, beat(), T0).instance;
    const { instance, events } = applyHeartbeat(first, beat({ stopping: true }), T0 + 1_000);
    expect(instance.online).toBe(false);
    expect(instance.offlineAt).toBe(T0 + 1_000);
    expect(instance.lastSeenAt).toBe(T0);
    expect(events).toEqual([{ type: "offline", instance, reason: "goodbye" }]);
  });

  it("goodbye on an already-offline instance emits no events", () => {
    const first = applyHeartbeat(undefined, beat(), T0).instance;
    const offline = applyHeartbeat(first, beat({ stopping: true }), T0 + 1_000).instance;
    const { events } = applyHeartbeat(offline, beat({ stopping: true }), T0 + 2_000);
    expect(events).toEqual([]);
  });

  it("goodbye from a never-seen instance emits no events", () => {
    const { instance, events } = applyHeartbeat(undefined, beat({ stopping: true }), T0);
    expect(instance.online).toBe(false);
    expect(events).toEqual([]);
  });
});

describe("expireInstances", () => {
  it("does not expire an instance under the timeout", () => {
    const instance = onlineInstance();
    const { expired, events } = expireInstances([instance], T0 + OFFLINE_TIMEOUT_MS - 1);
    expect(expired).toEqual([]);
    expect(events).toEqual([]);
  });

  it("expires exactly at the timeout boundary with reason timeout", () => {
    const instance = onlineInstance();
    const now = T0 + OFFLINE_TIMEOUT_MS;
    const { expired, events } = expireInstances([instance], now);
    expect(expired).toHaveLength(1);
    expect(expired[0]!.online).toBe(false);
    expect(expired[0]!.offlineAt).toBe(now);
    expect(expired[0]!.onlineSince).toBeUndefined();
    expect(events).toEqual([{ type: "offline", instance: expired[0]!, reason: "timeout" }]);
  });

  it("skips already-offline instances", () => {
    const offline = onlineInstance({ online: false, onlineSince: undefined, offlineAt: T0 });
    const { expired } = expireInstances([offline], T0 + 10 * OFFLINE_TIMEOUT_MS);
    expect(expired).toEqual([]);
  });

  it("expires only the timed-out subset", () => {
    const stale = onlineInstance({ tag: "stale" });
    const fresh = onlineInstance({ tag: "fresh", lastSeenAt: T0 + OFFLINE_TIMEOUT_MS - 1 });
    const { expired } = expireInstances([stale, fresh], T0 + OFFLINE_TIMEOUT_MS);
    expect(expired.map((i) => i.tag)).toEqual(["stale"]);
  });
});

describe("shouldPrune", () => {
  it("never prunes online instances", () => {
    expect(shouldPrune(onlineInstance(), T0 + 100 * PRUNE_AFTER_MS)).toBe(false);
  });

  it("prunes offline instances after the retention window", () => {
    const offline = onlineInstance({ online: false, offlineAt: T0 });
    expect(shouldPrune(offline, T0 + PRUNE_AFTER_MS - 1)).toBe(false);
    expect(shouldPrune(offline, T0 + PRUNE_AFTER_MS)).toBe(true);
  });

  it("falls back to lastSeenAt when offlineAt is missing", () => {
    const offline = onlineInstance({ online: false, offlineAt: undefined, lastSeenAt: T0 });
    expect(shouldPrune(offline, T0 + PRUNE_AFTER_MS)).toBe(true);
  });
});

describe("nextAlarmTime", () => {
  it("is null with no instances", () => {
    expect(nextAlarmTime([])).toBeNull();
  });

  it("is the earliest expiry deadline across online instances", () => {
    const early = onlineInstance({ tag: "a", lastSeenAt: T0 });
    const late = onlineInstance({ tag: "b", lastSeenAt: T0 + 10_000 });
    expect(nextAlarmTime([late, early])).toBe(T0 + OFFLINE_TIMEOUT_MS);
  });

  it("uses the prune deadline for offline instances", () => {
    const offline = onlineInstance({ online: false, offlineAt: T0 });
    expect(nextAlarmTime([offline])).toBe(T0 + PRUNE_AFTER_MS);
  });
});

describe("buildSnapshot", () => {
  it("rolls instances up per device, online if any instance is online", () => {
    const deviceA = "11111111-2222-4333-8444-555555555555";
    const deviceB = "99999999-2222-4333-8444-555555555555";
    const snapshot = buildSnapshot(
      "team-1",
      [
        onlineInstance({ deviceId: deviceA, tag: "default", online: false, offlineAt: T0, lastSeenAt: T0 }),
        onlineInstance({ deviceId: deviceA, tag: "dev", lastSeenAt: T0 + 1_000, displayName: "Studio" }),
        onlineInstance({ deviceId: deviceB, tag: "default", online: false, offlineAt: T0, lastSeenAt: T0 - 1 }),
      ],
      T0 + 2_000,
    );
    expect(snapshot.type).toBe("snapshot");
    expect(snapshot.teamId).toBe("team-1");
    expect(snapshot.heartbeatIntervalMs).toBe(HEARTBEAT_INTERVAL_MS);
    expect(snapshot.devices).toHaveLength(2);
    const [first, second] = snapshot.devices;
    expect(first!.deviceId).toBe(deviceA);
    expect(first!.online).toBe(true);
    expect(first!.displayName).toBe("Studio");
    expect(first!.lastSeenAt).toBe(T0 + 1_000);
    expect(first!.instances.map((i) => i.tag)).toEqual(["dev", "default"]);
    expect(second!.deviceId).toBe(deviceB);
    expect(second!.online).toBe(false);
  });
});

describe("checkDeviceOwner", () => {
  it("pins the first authenticated user as the device owner", () => {
    expect(checkDeviceOwner(undefined, "user-1")).toEqual({ ok: true, pin: true });
  });

  it("accepts further heartbeats from the pinned owner without re-pinning", () => {
    expect(checkDeviceOwner("user-1", "user-1")).toEqual({ ok: true, pin: false });
  });

  it("rejects a different team member announcing the same device", () => {
    expect(checkDeviceOwner("user-1", "user-2")).toEqual({
      ok: false,
      error: "device_owner_mismatch",
    });
  });
});

describe("checkPresenceCaps", () => {
  it("mirrors the registry caps", () => {
    // web/app/api/devices/route.ts: MAX_DEVICES_PER_TEAM / MAX_INSTANCES_PER_DEVICE.
    expect(MAX_DEVICES_PER_TEAM).toBe(200);
    expect(MAX_INSTANCES_PER_DEVICE).toBe(25);
  });

  it("accepts a new device and instance under both caps", () => {
    expect(
      checkPresenceCaps({
        isNewDevice: true,
        teamDeviceCount: MAX_DEVICES_PER_TEAM - 1,
        isNewInstance: true,
        deviceInstanceCount: MAX_INSTANCES_PER_DEVICE - 1,
      }),
    ).toEqual({ ok: true });
  });

  it("rejects the device that would exceed the per-team device cap", () => {
    expect(
      checkPresenceCaps({
        isNewDevice: true,
        teamDeviceCount: MAX_DEVICES_PER_TEAM,
        isNewInstance: true,
        deviceInstanceCount: 0,
      }),
    ).toEqual({ ok: false, error: "too_many_devices" });
  });

  it("rejects the tag that would exceed the per-device instance cap", () => {
    // One member minting unbounded tags for a single device must hit the
    // 25-instance bound, not the whole team's budget.
    expect(
      checkPresenceCaps({
        isNewDevice: false,
        teamDeviceCount: 0,
        isNewInstance: true,
        deviceInstanceCount: MAX_INSTANCES_PER_DEVICE,
      }),
    ).toEqual({ ok: false, error: "too_many_instances" });
  });

  it("ignores the device cap for a heartbeat on an already-pinned device", () => {
    // A full team must not lock out heartbeats from its existing devices.
    expect(
      checkPresenceCaps({
        isNewDevice: false,
        teamDeviceCount: MAX_DEVICES_PER_TEAM,
        isNewInstance: false,
        deviceInstanceCount: MAX_INSTANCES_PER_DEVICE,
      }),
    ).toEqual({ ok: true });
  });
});

describe("resolveSubscribeDeadline", () => {
  const MAX_AGE = 15 * 60 * 1000;

  it("passes through a future deadline under the cap", () => {
    expect(resolveSubscribeDeadline(String(T0 + 60_000), T0, MAX_AGE)).toBe(T0 + 60_000);
  });

  it("re-caps a deadline beyond the max age", () => {
    expect(resolveSubscribeDeadline(String(T0 + MAX_AGE * 2), T0, MAX_AGE)).toBe(T0 + MAX_AGE);
  });

  it("rejects a deadline already in the past instead of minting a fresh window", () => {
    // A token that expired between worker verification and DO handling must
    // not buy another max-age window of stream.
    expect(resolveSubscribeDeadline(String(T0 - 1), T0, MAX_AGE)).toBeNull();
    expect(resolveSubscribeDeadline(String(T0), T0, MAX_AGE)).toBeNull();
  });

  it("rejects a missing or garbled header", () => {
    expect(resolveSubscribeDeadline(null, T0, MAX_AGE)).toBeNull();
    expect(resolveSubscribeDeadline("", T0, MAX_AGE)).toBeNull();
    expect(resolveSubscribeDeadline("not-a-number", T0, MAX_AGE)).toBeNull();
    expect(resolveSubscribeDeadline("Infinity", T0, MAX_AGE)).toBeNull();
  });
});

describe("heartbeat routes", () => {
  const routeA = { kind: "lan", host: "192.168.1.10", port: 49152 };
  const routeB = { kind: "tailscale", host: "mac.tailnet.ts.net", port: 49152 };
  const routeMoved = { kind: "lan", host: "192.168.1.10", port: 50000 };

  it("stores routes from the first heartbeat on the online instance", () => {
    const { instance, events } = applyHeartbeat(undefined, beat({ routes: [routeA, routeB] }), T0);
    expect(instance.routes).toEqual([routeA, routeB]);
    expect(events).toEqual([{ type: "online", instance }]);
  });

  it("absent routes keep the previous set and tick seen", () => {
    const existing = onlineInstance({ routes: [routeA] });
    const { instance, events } = applyHeartbeat(existing, beat(), T0 + 15_000);
    expect(instance.routes).toEqual([routeA]);
    expect(events).toEqual([
      { type: "seen", deviceId: instance.deviceId, tag: instance.tag, lastSeenAt: T0 + 15_000 },
    ]);
  });

  it("a changed route set on an online instance emits a routes push", () => {
    const existing = onlineInstance({ routes: [routeA] });
    const { instance, events } = applyHeartbeat(existing, beat({ routes: [routeMoved] }), T0 + 15_000);
    expect(instance.routes).toEqual([routeMoved]);
    expect(events).toEqual([{ type: "routes", instance }]);
  });

  it("route order is meaning: a reordered set is a change", () => {
    const existing = onlineInstance({ routes: [routeA, routeB] });
    const { events } = applyHeartbeat(existing, beat({ routes: [routeB, routeA] }), T0 + 15_000);
    expect(events[0]?.type).toBe("routes");
  });

  it("an unchanged route set is only a seen tick", () => {
    const existing = onlineInstance({ routes: [routeA, routeB] });
    const { events } = applyHeartbeat(existing, beat({ routes: [routeA, routeB] }), T0 + 15_000);
    expect(events[0]?.type).toBe("seen");
  });

  it("an explicit empty set clears routes and emits a routes push", () => {
    const existing = onlineInstance({ routes: [routeA] });
    const { instance, events } = applyHeartbeat(existing, beat({ routes: [] }), T0 + 15_000);
    expect(instance.routes).toEqual([]);
    expect(events).toEqual([{ type: "routes", instance }]);
  });

  it("routes on a fresh online transition ride the online event, not a routes push", () => {
    const offline = onlineInstance({ online: false, onlineSince: undefined, offlineAt: T0, routes: [routeA] });
    const { instance, events } = applyHeartbeat(offline, beat({ routes: [routeMoved] }), T0 + 60_000);
    expect(instance.routes).toEqual([routeMoved]);
    expect(events).toEqual([{ type: "online", instance }]);
  });

  it("a goodbye keeps the last known routes on the offline record", () => {
    const existing = onlineInstance({ routes: [routeA] });
    const { instance } = applyHeartbeat(existing, beat({ stopping: true }), T0 + 15_000);
    expect(instance.online).toBe(false);
    expect(instance.routes).toEqual([routeA]);
  });

  it("routesEqual is order-sensitive and treats undefined as distinct from empty", () => {
    expect(routesEqual(undefined, undefined)).toBe(true);
    expect(routesEqual(undefined, [])).toBe(false);
    expect(routesEqual([], [])).toBe(true);
    expect(routesEqual([routeA], [routeA])).toBe(true);
    expect(routesEqual([routeA, routeB], [routeB, routeA])).toBe(false);
  });

  it("snapshot instances carry their stored routes", () => {
    const snapshot = buildSnapshot("team-1", [onlineInstance({ routes: [routeA] })], T0);
    expect(snapshot.devices[0]?.instances[0]?.routes).toEqual([routeA]);
  });
});
