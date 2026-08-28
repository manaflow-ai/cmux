// Signout/prune/purge removal lifecycle tests, against the same Map-backed
// `SyncStorage` fake as syncStorage.test.ts (no Workers runtime). These cover
// the storage semantics do.ts delegates: a signout goodbye deletes the
// instance (not just flips it offline), the owner pin is released exactly when
// a device's last instance goes away, the alarm's sweep releases pins for
// instance-less devices, and the account purge removes every device a user
// owns while leaving co-members' devices alone.

import { describe, expect, it } from "bun:test";
import {
  INSTANCE_PREFIX,
  instanceKey,
  ownerKey,
  purgeUserDevices,
  removeInstanceForSignout,
  sweepOrphanedOwnerPins,
} from "../src/presenceStorage";
import {
  PRUNE_AFTER_MS,
  shouldPrune,
  type HeartbeatInput,
  type PresenceInstance,
} from "../src/core";
import { reconcileSingleDevice, type DeviceRecord } from "../src/syncDevices";
import { listRecords, readRecord, type SyncStorage } from "../src/syncStorage";

const T0 = 1_750_000_000_000;
const DEV_A = "dev-A";
const DEV_B = "dev-B";
const DEV_C = "dev-C";

class FakeStorage implements SyncStorage {
  private map = new Map<string, unknown>();
  async get<T>(key: string): Promise<T | undefined> {
    return this.map.get(key) as T | undefined;
  }
  async put<T>(keyOrEntries: string | Record<string, unknown>, value?: T): Promise<void> {
    if (typeof keyOrEntries === "string") {
      this.map.set(keyOrEntries, JSON.parse(JSON.stringify(value)));
      return;
    }
    for (const [k, v] of Object.entries(keyOrEntries)) {
      this.map.set(k, JSON.parse(JSON.stringify(v)));
    }
  }
  async delete(key: string): Promise<boolean> {
    return this.map.delete(key);
  }
  async list<T>(options: { prefix: string; limit?: number }): Promise<Map<string, T>> {
    const out = new Map<string, T>();
    const keys = [...this.map.keys()].filter((k) => k.startsWith(options.prefix)).sort();
    for (const k of keys) {
      if (options.limit !== undefined && out.size >= options.limit) break;
      out.set(k, this.map.get(k) as T);
    }
    return out;
  }
}

function instance(overrides: Partial<PresenceInstance> = {}): PresenceInstance {
  return {
    deviceId: DEV_A,
    tag: "default",
    platform: "mac",
    capabilities: [],
    online: true,
    lastSeenAt: T0,
    onlineSince: T0,
    ...overrides,
  };
}

function signoutBeat(overrides: Partial<HeartbeatInput> = {}): HeartbeatInput {
  return {
    deviceId: DEV_A,
    tag: "default",
    platform: "mac",
    stopping: true,
    signout: true,
    ...overrides,
  };
}

/** Seed an instance + owner pin and project the device into the sync
 * collection, the way heartbeats would have. */
async function seedDevice(
  storage: FakeStorage,
  instances: PresenceInstance[],
  owner: string,
): Promise<void> {
  for (const inst of instances) {
    await storage.put(instanceKey(inst.deviceId, inst.tag), inst);
  }
  const deviceId = instances[0]!.deviceId;
  await storage.put(ownerKey(deviceId), owner);
  await reconcileSingleDevice(storage, deviceId, instances, owner, T0);
}

async function liveDeviceIds(storage: FakeStorage): Promise<Set<string>> {
  const map = await storage.list<PresenceInstance>({ prefix: INSTANCE_PREFIX });
  return new Set([...map.values()].map((inst) => inst.deviceId));
}

describe("removeInstanceForSignout", () => {
  it("removes the last instance, emits an offline goodbye, releases the pin, and tombstones the device", async () => {
    const storage = new FakeStorage();
    const existing = instance();
    await seedDevice(storage, [existing], "user-1");

    const removal = await removeInstanceForSignout(storage, existing, signoutBeat(), T0 + 1_000);

    // Instance record deleted, not stored offline.
    expect(await storage.get(instanceKey(DEV_A, "default"))).toBeUndefined();
    // Offline event with reason "goodbye" (old-decoder compat), offline echo.
    expect(removal.events).toHaveLength(1);
    expect(removal.events[0]).toMatchObject({
      type: "offline",
      reason: "goodbye",
      instance: { deviceId: DEV_A, online: false, offlineAt: T0 + 1_000 },
    });
    expect(removal.instance.online).toBe(false);
    // Last instance gone: pin released.
    expect(removal.ownerPinReleased).toBe(true);
    expect(await storage.get(ownerKey(DEV_A))).toBeUndefined();
    // Synced device record tombstoned, delta returned for broadcast.
    expect(removal.deltas).toHaveLength(1);
    expect(removal.deltas[0]!.records[0]).toMatchObject({ id: DEV_A, deleted: true });
    expect((await readRecord(storage, "devices", DEV_A))?.deleted).toBe(true);
  });

  it("keeps the pin and the live device record when another tag remains", async () => {
    const storage = new FakeStorage();
    const stable = instance();
    const dev = instance({ tag: "dev", lastSeenAt: T0 + 1 });
    await seedDevice(storage, [stable, dev], "user-1");

    const removal = await removeInstanceForSignout(
      storage,
      stable,
      signoutBeat(),
      T0 + 1_000,
    );

    expect(await storage.get(instanceKey(DEV_A, "default"))).toBeUndefined();
    expect(await storage.get<PresenceInstance>(instanceKey(DEV_A, "dev"))).toMatchObject({ tag: "dev" });
    // Another instance remains: pin survives.
    expect(removal.ownerPinReleased).toBe(false);
    expect(await storage.get<string>(ownerKey(DEV_A))).toBe("user-1");
    // Device record shrinks to the surviving tag instead of tombstoning.
    expect(removal.deltas).toHaveLength(1);
    const record = removal.deltas[0]!.records[0]!;
    expect(record.deleted).toBe(false);
    expect((record.payload as DeviceRecord).instances.map((i) => i.tag)).toEqual(["dev"]);
  });

  it("removes an already-offline instance silently (no duplicate offline event)", async () => {
    const storage = new FakeStorage();
    const offline = instance({ online: false, onlineSince: undefined, offlineAt: T0 });
    await seedDevice(storage, [offline], "user-1");

    const removal = await removeInstanceForSignout(storage, offline, signoutBeat(), T0 + 1_000);

    expect(removal.events).toEqual([]);
    expect(await storage.get(instanceKey(DEV_A, "default"))).toBeUndefined();
    expect(removal.ownerPinReleased).toBe(true);
    expect(removal.deltas[0]!.records[0]).toMatchObject({ id: DEV_A, deleted: true });
  });
});

describe("sweepOrphanedOwnerPins", () => {
  it("releases pins for devices whose instances were all pruned, keeping live devices' pins", async () => {
    const storage = new FakeStorage();
    // Mirror the alarm: a 24h-offline instance is pruned, then the sweep runs
    // against the surviving map.
    const prunable = instance({ deviceId: DEV_A, online: false, onlineSince: undefined, offlineAt: T0 });
    const fresh = instance({ deviceId: DEV_B, lastSeenAt: T0 + PRUNE_AFTER_MS });
    await storage.put(instanceKey(DEV_A, "default"), prunable);
    await storage.put(instanceKey(DEV_B, "default"), fresh);
    await storage.put(ownerKey(DEV_A), "user-1");
    await storage.put(ownerKey(DEV_B), "user-2");

    const now = T0 + PRUNE_AFTER_MS;
    for (const [key, inst] of await storage.list<PresenceInstance>({ prefix: INSTANCE_PREFIX })) {
      if (shouldPrune(inst, now)) await storage.delete(key);
    }
    const released = await sweepOrphanedOwnerPins(storage, await liveDeviceIds(storage));

    expect(released).toEqual([DEV_A]);
    expect(await storage.get(ownerKey(DEV_A))).toBeUndefined();
    expect(await storage.get<string>(ownerKey(DEV_B))).toBe("user-2");
  });
});

describe("purgeUserDevices", () => {
  it("purges every device the user owns and leaves co-members' devices alone", async () => {
    const storage = new FakeStorage();
    // user-1: DEV_A (one online + one offline instance) and a stale pin on
    // DEV_B (no instances, pre-release-rule leftover). user-2: DEV_C.
    await seedDevice(storage, [
      instance({ deviceId: DEV_A }),
      instance({ deviceId: DEV_A, tag: "dev", online: false, onlineSince: undefined, offlineAt: T0 }),
    ], "user-1");
    await storage.put(ownerKey(DEV_B), "user-1");
    await seedDevice(storage, [instance({ deviceId: DEV_C })], "user-2");

    const result = await purgeUserDevices(storage, "user-1", T0 + 5_000);

    expect(result.devicesPurged).toBe(2);
    // Only the online instance produces an offline goodbye.
    expect(result.events).toHaveLength(1);
    expect(result.events[0]).toMatchObject({
      type: "offline",
      reason: "goodbye",
      instance: { deviceId: DEV_A, tag: "default", online: false, offlineAt: T0 + 5_000 },
    });
    // user-1's instances and pins are gone.
    expect((await storage.list({ prefix: `${INSTANCE_PREFIX}${DEV_A}:` })).size).toBe(0);
    expect(await storage.get(ownerKey(DEV_A))).toBeUndefined();
    expect(await storage.get(ownerKey(DEV_B))).toBeUndefined();
    // DEV_A had a synced record: tombstoned + delta. DEV_B never did: no delta.
    expect(result.deltas).toHaveLength(1);
    expect(result.deltas[0]!.records[0]).toMatchObject({ id: DEV_A, deleted: true });
    // user-2 untouched: pin, instance, and live synced record remain.
    expect(await storage.get<string>(ownerKey(DEV_C))).toBe("user-2");
    expect((await storage.list({ prefix: `${INSTANCE_PREFIX}${DEV_C}:` })).size).toBe(1);
    const records = await listRecords<DeviceRecord>(storage, "devices");
    expect(records.filter((r) => !r.deleted).map((r) => r.id)).toEqual([DEV_C]);
  });

  it("is a counted no-op for a user who owns nothing here", async () => {
    const storage = new FakeStorage();
    await seedDevice(storage, [instance({ deviceId: DEV_C })], "user-2");

    const result = await purgeUserDevices(storage, "user-1", T0 + 5_000);

    expect(result).toEqual({ devicesPurged: 0, events: [], deltas: [] });
    expect(await storage.get<string>(ownerKey(DEV_C))).toBe("user-2");
  });
});
