import { describe, expect, test } from "bun:test";
import { canBindingDiscoverPeer } from "../services/iroh/buildCompatibility";
import {
  discoveryRegistrationTouchInterval,
  filterDiscoverableDevices,
  registrationDiscoveryLabels,
} from "../services/iroh/registryDiscovery";
import { registrationIsUnchanged } from "../services/devices/registrationNoOp";

const caller = { platform: "mac", deviceUuid: "local", tag: "my-feature", clientNamespace: "mac:com.cmuxterm.app.debug.my.feature" };
const target = { ...caller, deviceUuid: "remote", pairingEnabled: true };

describe("automatic personal Mac discovery", () => {
  test("allows the same dev tag, stable and nightly on another opted-in Mac", () => {
    for (const tag of ["my-feature", "default", "nightly"]) {
      expect(canBindingDiscoverPeer(caller, { ...target, tag })).toBe(true);
    }
  });
  test("rejects other dev tags, self, non-Mac namespaces, and disabled hosting", () => {
    for (const peer of [
      { ...target, tag: "another-feature" }, { ...target, tag: "rc" }, { ...target, tag: "staging" },
      { ...target, deviceUuid: caller.deviceUuid }, { ...target, clientNamespace: "dev.cmux.ios.my-feature" },
      { ...target, pairingEnabled: false },
    ]) expect(canBindingDiscoverPeer(caller, peer)).toBe(false);
  });
  test("release Mac discovery stays in its exact channel", () => {
    expect(canBindingDiscoverPeer({ ...caller, tag: "default" }, { ...target, tag: "nightly" })).toBe(false);
    expect(canBindingDiscoverPeer({ ...caller, tag: "default" }, { ...target, tag: "default" })).toBe(true);
  });
  test("withdrawing one app instance hides only that instance and removes empty Mac identities", () => {
    const now = Date.parse("2026-09-10T00:00:00.000Z");
    const devices = [
      { platform: "mac", labels: {}, deviceId: "off", instances: [{ tag: "a", routes: [], lastSeenAt: new Date(now).toISOString() }] },
      { platform: "mac", labels: {}, deviceId: "mixed", instances: [{ tag: "off", routes: [], lastSeenAt: new Date(now).toISOString() }, { tag: "on", routes: [{}], lastSeenAt: new Date(now).toISOString() }] },
      { platform: "mac", labels: { manual: true }, deviceId: "manual", instances: [] },
    ];
    const visible = filterDiscoverableDevices(devices, now);
    expect(visible.map((device) => device.deviceId)).toEqual(["mixed", "manual"]);
    expect(visible[0]?.instances.map((instance) => instance.tag)).toEqual(["on"]);
    expect(devices[1]?.instances).toHaveLength(2);
  });

  test("uses the short lease for marked native registrations and legacy grace for unmarked rows", () => {
    const now = Date.parse("2026-09-10T00:00:00.000Z");
    const devices = [{
      platform: "mac", labels: {}, deviceId: "leases", instances: [
        { tag: "fresh", routes: [{}], labels: { discoveryLease: true }, lastSeenAt: new Date(now - 179_000).toISOString() },
        { tag: "expired", routes: [{}], labels: { discoveryLease: true }, lastSeenAt: new Date(now - 181_000).toISOString() },
        { tag: "legacy", routes: [{}], labels: {}, lastSeenAt: new Date(now - 24 * 60 * 60 * 1_000 + 1).toISOString() },
        { tag: "legacy-expired", routes: [{}], labels: {}, lastSeenAt: new Date(now - 24 * 60 * 60 * 1_000 - 1).toISOString() },
      ],
    }];
    const visible = filterDiscoverableDevices(devices, now);
    expect(visible[0]?.instances.map((instance) => instance.tag)).toEqual(["fresh", "legacy"]);
  });

  test("native renewal updates server time before lease expiry despite a five-minute no-op throttle", () => {
    const start = Date.parse("2026-09-10T00:00:00.000Z");
    const incoming = {
      userId: "owner", platform: "mac", displayName: "Mac", labels: {},
      instanceRoutes: [{}], instanceLabels: registrationDiscoveryLabels({ color: "blue" }, true),
    };
    let lastSeenAt = new Date(start);
    const touchIntervalMs = discoveryRegistrationTouchInterval(incoming.instanceLabels, 300_000);
    for (let seconds = 60; seconds <= 600; seconds += 60) {
      const now = new Date(start + seconds * 1_000);
      const unchanged = registrationIsUnchanged({
        stored: { ...incoming, lastSeenAt }, incoming, now, touchIntervalMs,
      });
      expect(unchanged).toBe(false);
      if (!unchanged) lastSeenAt = now;
      expect(filterDiscoverableDevices([{
        platform: "mac", labels: {}, instances: [{
          routes: incoming.instanceRoutes, labels: incoming.instanceLabels, lastSeenAt,
        }],
      }], now)).toHaveLength(1);
    }
    expect(discoveryRegistrationTouchInterval({}, 300_000)).toBe(300_000);
    expect(discoveryRegistrationTouchInterval(incoming.instanceLabels, 0)).toBe(0);
  });

  test("expiry is exclusive and invalid timestamps fail closed while manual remotes remain durable", () => {
    const now = Date.parse("2026-09-10T00:00:00.000Z");
    const expiredInstances = [
      { routes: [{}], labels: { discoveryLease: true }, lastSeenAt: new Date(now - 180_000) },
      { routes: [{}], labels: {}, lastSeenAt: new Date(now - 86_400_000) },
      { routes: [{}], labels: {}, lastSeenAt: "invalid" },
      { routes: [{}], labels: {}, lastSeenAt: new Date(now + 1) },
    ];
    const native = { platform: "mac", labels: {}, instances: expiredInstances };
    const manual = { ...native, labels: { manual: true } };
    expect(filterDiscoverableDevices([native], now)).toEqual([]);
    expect(filterDiscoverableDevices([manual], now)).toEqual([manual]);
  });

  test("only the top-level lease opt-in controls the reserved instance label", () => {
    expect(registrationDiscoveryLabels({ color: "blue", discoveryLease: true }, undefined)).toEqual({ color: "blue" });
    expect(registrationDiscoveryLabels({ color: "blue", discoveryLease: false }, true)).toEqual({ color: "blue", discoveryLease: true });
  });
});
