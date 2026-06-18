// Storage-bound sync tests. These exercise the half of the sync layer that
// touches DO storage, using a Map-backed `SyncStorage` fake (no Workers runtime,
// same posture as core.test.ts). They cover the protocol holes DESIGN.md §13
// flags: schemaVersion lazy upgrade, delta/cursor catch-up, snapshot
// rev-filtering with a concurrent delete during paging, the GC-floor forced
// resync, tombstone GC raising the floor, and derivation idempotency (a steady
// heartbeat must not bump rev).

import { beforeEach, describe, expect, it } from "bun:test";
import {
  buildCatchupDelta,
  buildSnapshotPages,
  gcTombstones,
  lazyUpgradeRecord,
  listRecords,
  markBackfillDone,
  nextTombstoneGcTime,
  readBackfillDone,
  readEpoch,
  readOrMintEpoch,
  readGcFloor,
  readHead,
  readRecord,
  resolveHelloFrames,
  tombstoneRecord,
  upsertRecord,
  type StoredSyncRecord,
  type SyncStorage,
} from "../src/syncStorage";
import { SYNC_SCHEMA_VERSION, TOMBSTONE_RETENTION_MS } from "../src/sync";
import {
  deriveDeviceRecord,
  groupInstancesByDevice,
  ownersFromList,
  reconcileDeviceRecords,
  reconcileSingleDevice,
  type DeviceRecord,
} from "../src/syncDevices";
import type { PresenceInstance } from "../src/core";

const T0 = 1_750_000_000_000;
const COLL = "devices";

/** Map-backed fake mirroring the subset of DurableObjectStorage sync uses.
 * `list` returns keys in lexical (sorted) order, matching the real DO contract
 * the rev-ordered tombstone GC depends on. */
class FakeStorage implements SyncStorage {
  private map = new Map<string, unknown>();
  async get<T>(key: string): Promise<T | undefined> {
    return this.map.get(key) as T | undefined;
  }
  async put<T>(keyOrEntries: string | Record<string, unknown>, value?: T): Promise<void> {
    // Mimic DurableObjectStorage.put: either a single key+value, or an atomic
    // multi-key entries object. Clone to mimic structured-clone semantics.
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
  /** Test helper: raw key access for asserting low-level storage shape. */
  raw<T>(key: string): T | undefined {
    return this.map.get(key) as T | undefined;
  }
}

function instance(overrides: Partial<PresenceInstance> = {}): PresenceInstance {
  return {
    deviceId: "dev-A",
    tag: "default",
    platform: "mac",
    capabilities: [],
    online: true,
    lastSeenAt: T0,
    onlineSince: T0,
    ...overrides,
  };
}

function devicePayload(overrides: Partial<DeviceRecord> = {}): DeviceRecord {
  return {
    deviceId: "dev-A",
    platform: "mac",
    lastSeenAtAtRev: T0,
    instances: [{ tag: "default", routes: [], lastSeenAtAtRev: T0 }],
    ...overrides,
  };
}

describe("upsertRecord (rev minting and no-op skip)", () => {
  let storage: FakeStorage;
  beforeEach(() => {
    storage = new FakeStorage();
  });

  it("mints rev=1 on first write and advances the head", async () => {
    const result = await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    expect(result.head).toBe(1);
    expect(result.delta).not.toBeNull();
    expect(result.delta!.rev).toBe(1);
    expect(result.delta!.records[0]!.rev).toBe(1);
    expect(await readHead(storage, COLL)).toBe(1);
  });

  it("is a no-op when the payload is byte-identical (cursor stays quiet)", async () => {
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    const again = await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0 + 1000);
    expect(again.delta).toBeNull();
    expect(again.head).toBe(1); // head did NOT advance
  });

  it("mints a new rev when the payload changes", async () => {
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    const changed = await upsertRecord(
      storage,
      COLL,
      "dev-A",
      devicePayload({ displayName: "Studio" }),
      T0 + 1000,
    );
    expect(changed.delta).not.toBeNull();
    expect(changed.head).toBe(2);
    expect(changed.delta!.records[0]!.rev).toBe(2);
  });

  it("honors a custom shapeEqual that ignores a noisy field", async () => {
    // shapeEqual returns true even though lastSeenAtAtRev differs => no-op.
    const ignoreTimestamp = (a: DeviceRecord, b: DeviceRecord) =>
      a.displayName === b.displayName;
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0, ignoreTimestamp);
    const tick = await upsertRecord(
      storage,
      COLL,
      "dev-A",
      devicePayload({ lastSeenAtAtRev: T0 + 99 }),
      T0 + 99,
      ignoreTimestamp,
    );
    expect(tick.delta).toBeNull();
    expect(tick.head).toBe(1);
  });
});

describe("delta catch-up (cursor math)", () => {
  it("returns only records with rev > cursor, in rev order, advancing to head", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    await upsertRecord(storage, COLL, "dev-B", devicePayload({ deviceId: "dev-B" }), T0);
    await upsertRecord(storage, COLL, "dev-A", devicePayload({ displayName: "x" }), T0);
    // head is now 3 (A@1, B@2, A@3).
    const delta = await buildCatchupDelta<DeviceRecord>(storage, COLL, 1);
    expect(delta).not.toBeNull();
    expect(delta!.rev).toBe(3); // advances cursor to head
    expect(delta!.records.map((r) => r.rev)).toEqual([2, 3]); // > cursor, rev-ordered
  });

  it("returns null when the client is already at head", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    expect(await buildCatchupDelta(storage, COLL, 1)).toBeNull();
  });
});

describe("snapshot rev-filtering and the concurrent-delete-during-paging race", () => {
  it("snapshot contains only rev <= snapshotRev; a later write is NOT folded in", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0); // rev 1
    await upsertRecord(storage, COLL, "dev-B", devicePayload({ deviceId: "dev-B" }), T0); // rev 2
    // Capture a snapshot at head=2.
    const snap = await buildSnapshotPages<DeviceRecord>(storage, COLL);
    expect(snap.snapshotRev).toBe(2);
    expect(snap.pages.at(-1)!.complete).toBe(true);
    const ids = snap.pages.flatMap((p) => p.records.map((r) => r.id));
    expect(ids.sort()).toEqual(["dev-A", "dev-B"]);
    expect(snap.pages.flatMap((p) => p.records).every((r) => r.rev <= 2)).toBe(true);
  });

  it("a delete racing the snapshot rides a later delta, never inside the snapshot", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0); // rev 1
    await upsertRecord(storage, COLL, "dev-B", devicePayload({ deviceId: "dev-B" }), T0); // rev 2
    // Snapshot captured at head=2 (contains A live, B live).
    const snap = await buildSnapshotPages<DeviceRecord>(storage, COLL);
    expect(snap.snapshotRev).toBe(2);
    // Now B is deleted mid-paging => tombstone at rev 3, ABOVE snapshotRev.
    const tomb = await tombstoneRecord(storage, COLL, "dev-B", T0 + 5);
    expect(tomb.head).toBe(3);
    // The snapshot the client committed shows B live; the delete is NOT in it.
    expect(snap.pages.flatMap((p) => p.records).find((r) => r.id === "dev-B")!.deleted).toBe(false);
    // The post-snapshot delta (rev > snapshotRev) carries the tombstone, so the
    // client drops B right after committing the snapshot — no ghost.
    const after = await buildCatchupDelta<DeviceRecord>(storage, COLL, snap.snapshotRev);
    expect(after!.records.map((r) => [r.id, r.deleted])).toEqual([["dev-B", true]]);
  });

  it("pages a large collection; all pages share snapshotRev, last is complete", async () => {
    const storage = new FakeStorage();
    for (let i = 0; i < 5; i++) {
      await upsertRecord(storage, COLL, `dev-${i}`, devicePayload({ deviceId: `dev-${i}` }), T0);
    }
    const snap = await buildSnapshotPages<DeviceRecord>(storage, COLL, 2);
    expect(snap.pages.map((p) => p.records.length)).toEqual([2, 2, 1]);
    expect(snap.pages.map((p) => p.complete)).toEqual([false, false, true]);
    expect(snap.pages.every((p) => p.snapshotRev === snap.snapshotRev)).toBe(true);
  });
});

describe("resolveHelloFrames (GC-floor forced resync, DESIGN §3.5)", () => {
  it("a first-time client (cursor 0) gets a full snapshot, not a delta", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    const resolved = await resolveHelloFrames<DeviceRecord>(storage, COLL, 0);
    expect(resolved.mode).toBe("snapshot");
    if (resolved.mode === "snapshot") {
      expect(resolved.snapshotRev).toBe(1);
      expect(resolved.pages.at(-1)!.complete).toBe(true);
      expect(resolved.pages.flatMap((p) => p.records).map((r) => r.id)).toEqual(["dev-A"]);
    }
  });

  it("a client at/above the floor with a matching epoch catches up with deltas", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0); // rev 1, mints epoch
    await upsertRecord(storage, COLL, "dev-A", devicePayload({ displayName: "y" }), T0); // rev 2
    const serverEpoch = await readEpoch(storage, COLL);
    // Passing the matching epoch keeps it a delta (an absent/stale epoch would
    // correctly force a resync, which is exercised separately).
    const resolved = await resolveHelloFrames<DeviceRecord>(storage, COLL, 1, undefined, serverEpoch);
    expect(resolved.mode).toBe("delta");
    if (resolved.mode === "delta") expect(resolved.delta!.rev).toBe(2);
  });

  it("a client BELOW the GC floor is forced to a full snapshot", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0); // rev 1
    await tombstoneRecord(storage, COLL, "dev-A", T0); // rev 2 tombstone
    // GC the tombstone (past retention) => floor rises to 2.
    const gc = await gcTombstones(storage, COLL, T0 + TOMBSTONE_RETENTION_MS + 1);
    expect(gc.floor).toBe(2);
    // A client whose cursor (1) is below the floor (2) may have missed the
    // deletion's tombstone, so it must be force-snapshotted.
    const resolved = await resolveHelloFrames<DeviceRecord>(storage, COLL, 1);
    expect(resolved.mode).toBe("snapshot");
  });
});

describe("tombstone GC raises the floor and removes records (DESIGN §3.5)", () => {
  it("does not GC a tombstone before the retention window", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    await tombstoneRecord(storage, COLL, "dev-A", T0); // rev 2 tombstone
    const gc = await gcTombstones(storage, COLL, T0 + TOMBSTONE_RETENTION_MS - 1);
    expect(gc.collected).toBe(0);
    expect(gc.floor).toBe(0);
    // Tombstone record and its index entry survive.
    expect(await readRecord(storage, COLL, "dev-A")).toBeDefined();
  });

  it("GCs an expired tombstone, deletes its record + index, raises the floor", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    await tombstoneRecord(storage, COLL, "dev-A", T0); // rev 2 tombstone
    const gc = await gcTombstones(storage, COLL, T0 + TOMBSTONE_RETENTION_MS);
    expect(gc.collected).toBe(1);
    expect(gc.floor).toBe(2);
    expect(await readRecord(storage, COLL, "dev-A")).toBeUndefined();
    expect(await readGcFloor(storage, COLL)).toBe(2);
    // Index entry gone too.
    const index = await storage.list({ prefix: "synctomb:devices:" });
    expect(index.size).toBe(0);
  });

  it("drops a stale index entry whose record came back to life without GCing it", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0); // rev 1
    await tombstoneRecord(storage, COLL, "dev-A", T0); // rev 2 tombstone + index@2
    // Device reappears: a new live record at rev 3 (the index@2 is now stale).
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0 + 1);
    const gc = await gcTombstones(storage, COLL, T0 + TOMBSTONE_RETENTION_MS * 2);
    // The live record is NOT deleted; only the stale index entry is cleaned up.
    expect(gc.collected).toBe(0);
    expect(await readRecord(storage, COLL, "dev-A")).toBeDefined();
    expect((await storage.list({ prefix: "synctomb:devices:" })).size).toBe(0);
  });
});

describe("schemaVersion lazy upgrade (DESIGN §5.3)", () => {
  it("rewrites an old-version record at a new rev via the upgrade callback", async () => {
    const storage = new FakeStorage();
    // Seed a record stamped at an OLD schema version directly in storage.
    const old: StoredSyncRecord<{ deviceId: string; legacyName: string }> = {
      id: "dev-A",
      rev: 1,
      updatedAt: T0,
      deleted: false,
      schemaVersion: SYNC_SCHEMA_VERSION - 1, // below current
      payload: { deviceId: "dev-A", legacyName: "Old" },
    };
    await storage.put("synced:devices:dev-A", old);
    await storage.put("synchead:devices", 1);

    const result = await lazyUpgradeRecord<{ deviceId: string; legacyName?: string; displayName?: string }>(
      storage,
      COLL,
      "dev-A",
      T0 + 10,
      (payload) => ({ deviceId: payload.deviceId, displayName: (payload as { legacyName: string }).legacyName }),
    );
    expect(result.delta).not.toBeNull();
    expect(result.head).toBe(2); // re-stamped at a new rev so clients re-pull
    const upgraded = await readRecord<{ displayName?: string }>(storage, COLL, "dev-A");
    expect(upgraded!.schemaVersion).toBe(SYNC_SCHEMA_VERSION);
    expect(upgraded!.rev).toBe(2);
    expect(upgraded!.payload.displayName).toBe("Old");
  });

  it("is a no-op when the record is already at the current schema version", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0); // current version
    const result = await lazyUpgradeRecord(storage, COLL, "dev-A", T0 + 10, (p) => p);
    expect(result.delta).toBeNull();
    expect(result.head).toBe(1);
  });
});

describe("device derivation idempotency through reconcileDeviceRecords (DESIGN §5.2)", () => {
  it("a steady heartbeat (no list-shape change) does NOT bump rev", async () => {
    const storage = new FakeStorage();
    const owners = new Map<string, string>();
    // First derivation: device appears, rev -> 1.
    let deltas = await reconcileDeviceRecords(
      storage,
      groupInstancesByDevice([instance()]),
      ownersFromList(owners),
      T0,
    );
    expect(deltas).toHaveLength(1);
    expect(await readHead(storage, COLL)).toBe(1);

    // A pure `seen` tick: same routes/tags/identity, only lastSeenAt advanced.
    // The derived record's list-shape is identical, so NO new rev.
    deltas = await reconcileDeviceRecords(
      storage,
      groupInstancesByDevice([instance({ lastSeenAt: T0 + 15_000 })]),
      ownersFromList(owners),
      T0 + 15_000,
    );
    expect(deltas).toHaveLength(0);
    expect(await readHead(storage, COLL)).toBe(1); // quiet cursor
  });

  it("an online->offline flip does NOT bump rev (record carries no `online`)", async () => {
    const storage = new FakeStorage();
    const owners = new Map<string, string>();
    await reconcileDeviceRecords(storage, groupInstancesByDevice([instance()]), ownersFromList(owners), T0);
    expect(await readHead(storage, COLL)).toBe(1);
    // Same device, now offline. lastSeenAtAtRev does not gate shape => no rev.
    const deltas = await reconcileDeviceRecords(
      storage,
      groupInstancesByDevice([instance({ online: false, offlineAt: T0 + 45_000 })]),
      ownersFromList(owners),
      T0 + 45_000,
    );
    expect(deltas).toHaveLength(0);
    expect(await readHead(storage, COLL)).toBe(1);
  });

  it("a routes change DOES bump rev and emit a delta", async () => {
    const storage = new FakeStorage();
    const owners = new Map<string, string>();
    await reconcileDeviceRecords(storage, groupInstancesByDevice([instance()]), ownersFromList(owners), T0);
    const deltas = await reconcileDeviceRecords(
      storage,
      groupInstancesByDevice([instance({ routes: [{ kind: "lan", host: "1.2.3.4" }] })]),
      ownersFromList(owners),
      T0 + 1000,
    );
    expect(deltas).toHaveLength(1);
    expect(await readHead(storage, COLL)).toBe(2);
  });

  it("a new tag (instance) on the device DOES bump rev", async () => {
    const storage = new FakeStorage();
    const owners = new Map<string, string>();
    await reconcileDeviceRecords(storage, groupInstancesByDevice([instance()]), ownersFromList(owners), T0);
    const deltas = await reconcileDeviceRecords(
      storage,
      groupInstancesByDevice([instance(), instance({ tag: "rc" })]),
      ownersFromList(owners),
      T0 + 1000,
    );
    expect(deltas).toHaveLength(1);
    expect(await readHead(storage, COLL)).toBe(2);
  });

  it("a device whose last instance is gone gets tombstoned (leaves the list)", async () => {
    const storage = new FakeStorage();
    const owners = new Map<string, string>();
    await reconcileDeviceRecords(storage, groupInstancesByDevice([instance()]), ownersFromList(owners), T0); // rev 1
    // Next pass: no instances at all (the device was pruned).
    const deltas = await reconcileDeviceRecords(storage, new Map(), ownersFromList(owners), T0 + 1000);
    expect(deltas).toHaveLength(1);
    expect(deltas[0]!.records[0]!.deleted).toBe(true);
    expect(await readHead(storage, COLL)).toBe(2);
    // A second prune pass is idempotent: already a tombstone, no new rev.
    const again = await reconcileDeviceRecords(storage, new Map(), ownersFromList(owners), T0 + 2000);
    expect(again).toHaveLength(0);
    expect(await readHead(storage, COLL)).toBe(2);
  });

  it("carries the owner pin onto the derived record", async () => {
    const storage = new FakeStorage();
    const owners = new Map<string, string>([["owner:dev-A", "user-123"]]);
    await reconcileDeviceRecords(storage, groupInstancesByDevice([instance()]), ownersFromList(owners), T0);
    const rec = await readRecord<DeviceRecord>(storage, COLL, "dev-A");
    expect(rec!.payload.ownerUserId).toBe("user-123");
  });
});

describe("rollout backfill marker (head != 0 is not completion, DESIGN §5.4)", () => {
  it("defaults to not-done and flips on mark", async () => {
    const storage = new FakeStorage();
    expect(await readBackfillDone(storage, COLL)).toBe(false);
    await markBackfillDone(storage, COLL);
    expect(await readBackfillDone(storage, COLL)).toBe(true);
  });

  it("is independent of the head being nonzero", async () => {
    const storage = new FakeStorage();
    // One device projects (head becomes 1) but backfill never ran: still not done.
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    expect(await readHead(storage, COLL)).toBe(1);
    expect(await readBackfillDone(storage, COLL)).toBe(false);
  });
});

describe("collection epoch (equal-head reset detection, DESIGN §3.6)", () => {
  it("mints once and is stable across reads", async () => {
    const storage = new FakeStorage();
    expect(await readEpoch(storage, COLL)).toBe(0);
    const e1 = await readOrMintEpoch(storage, COLL, T0);
    expect(e1).toBe(T0);
    // A later read returns the SAME minted epoch (not re-minted).
    expect(await readOrMintEpoch(storage, COLL, T0 + 999)).toBe(T0);
    expect(await readEpoch(storage, COLL)).toBe(T0);
  });

  it("is minted on the FIRST write so equal-head reset detection is never disabled", async () => {
    const storage = new FakeStorage();
    expect(await readEpoch(storage, COLL)).toBe(0);
    // The first upsert mints the epoch atomically with the head.
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    expect(await readEpoch(storage, COLL)).toBe(T0);
    // A subsequent write does NOT change the epoch.
    await upsertRecord(storage, COLL, "dev-B", devicePayload({ deviceId: "dev-B" }), T0 + 5);
    expect(await readEpoch(storage, COLL)).toBe(T0);
  });

  it("resolveHelloFrames mints an epoch for pre-epoch records (head>0, epoch 0)", async () => {
    const storage = new FakeStorage();
    // Simulate legacy data: records + head exist but no epoch key (pre-this-fix).
    await storage.put("synced:devices:dev-A", { id: "dev-A", rev: 1, updatedAt: T0, deleted: false, schemaVersion: 1, payload: {} });
    await storage.put("synchead:devices", 1);
    expect(await readEpoch(storage, COLL)).toBe(0);
    // A client at the same head with a stale (nonzero) epoch must be snapshotted,
    // which requires the server to mint an epoch to compare against.
    const resolved = await resolveHelloFrames<DeviceRecord>(storage, COLL, 1, undefined, 999, T0);
    expect(await readEpoch(storage, COLL)).toBe(T0); // minted
    expect(resolved.mode).toBe("snapshot"); // mismatch (999 != T0) forces resync
  });

  it("a snapshot carries the minted epoch on every page", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    const snap = await buildSnapshotPages<DeviceRecord>(storage, COLL, undefined, T0);
    expect(snap.epoch).toBe(T0);
    expect(snap.pages.every((p) => p.epoch === T0)).toBe(true);
  });

  it("resolveHelloFrames forces a snapshot on an epoch mismatch at an equal head", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0); // head 1, mints epoch on snapshot
    // Establish the server epoch.
    const serverEpoch = await readOrMintEpoch(storage, COLL, T0);
    // A client at the current head but a STALE epoch must be force-snapshotted.
    const resolved = await resolveHelloFrames<DeviceRecord>(storage, COLL, 1, undefined, serverEpoch - 1, T0);
    expect(resolved.mode).toBe("snapshot");
    // The matching epoch at the current head catches up with a (null) delta.
    const ok = await resolveHelloFrames<DeviceRecord>(storage, COLL, 1, undefined, serverEpoch, T0);
    expect(ok.mode).toBe("delta");
  });
});

describe("reconcileSingleDevice (heartbeat hot path, bounded work)", () => {
  it("upserts just the one device and mints a rev only on a shape change", async () => {
    const storage = new FakeStorage();
    // First reconcile of dev-A: appears, rev -> 1.
    let delta = await reconcileSingleDevice(storage, "dev-A", [instance()], undefined, T0);
    expect(delta).not.toBeNull();
    expect(await readHead(storage, COLL)).toBe(1);
    // A steady `seen` tick on the same device: no shape change, no rev.
    delta = await reconcileSingleDevice(storage, "dev-A", [instance({ lastSeenAt: T0 + 15_000 })], undefined, T0 + 15_000);
    expect(delta).toBeNull();
    expect(await readHead(storage, COLL)).toBe(1);
    // A routes change on the same device: new rev.
    delta = await reconcileSingleDevice(storage, "dev-A", [instance({ routes: [{ kind: "lan" }] })], undefined, T0 + 1000);
    expect(delta).not.toBeNull();
    expect(await readHead(storage, COLL)).toBe(2);
  });

  it("does NOT touch other devices (bounded to the one passed)", async () => {
    const storage = new FakeStorage();
    await reconcileSingleDevice(storage, "dev-A", [instance()], undefined, T0);
    await reconcileSingleDevice(storage, "dev-B", [instance({ deviceId: "dev-B" })], undefined, T0);
    // Reconciling A again must not tombstone B (B has no instances in THIS call,
    // but single-device reconcile only ever touches its own id).
    const delta = await reconcileSingleDevice(storage, "dev-A", [instance()], undefined, T0 + 1);
    expect(delta).toBeNull();
    const all = await listRecords<DeviceRecord>(storage, COLL);
    expect(all.filter((r) => !r.deleted).map((r) => r.id).sort()).toEqual(["dev-A", "dev-B"]);
  });

  it("tombstones the device when its last instance is gone (goodbye path)", async () => {
    const storage = new FakeStorage();
    await reconcileSingleDevice(storage, "dev-A", [instance()], undefined, T0); // rev 1
    const delta = await reconcileSingleDevice(storage, "dev-A", [], undefined, T0 + 1000);
    expect(delta).not.toBeNull();
    expect(delta!.records[0]!.deleted).toBe(true);
    expect(await readHead(storage, COLL)).toBe(2);
  });
});

describe("nextTombstoneGcTime (alarm scheduling so offline teams still GC)", () => {
  it("returns null when there are no tombstones", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    expect(await nextTombstoneGcTime(storage, COLL)).toBeNull();
  });

  it("returns the earliest tombstone's retention deadline", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0); // rev 1
    await upsertRecord(storage, COLL, "dev-B", devicePayload({ deviceId: "dev-B" }), T0); // rev 2
    await tombstoneRecord(storage, COLL, "dev-A", T0 + 5_000); // tombstone, updatedAt later
    await tombstoneRecord(storage, COLL, "dev-B", T0); // tombstone, updatedAt earlier
    // The earliest GC deadline is the earliest tombstone updatedAt + retention.
    expect(await nextTombstoneGcTime(storage, COLL)).toBe(T0 + TOMBSTONE_RETENTION_MS);
  });
});

describe("deriveDeviceRecord edge cases", () => {
  it("returns null for a device with no instances (tombstone, not record)", () => {
    expect(deriveDeviceRecord("dev-A", [], undefined)).toBeNull();
  });

  it("picks newest lastSeenAt and the first defined displayName", () => {
    const rec = deriveDeviceRecord(
      "dev-A",
      [
        instance({ tag: "a", lastSeenAt: T0, displayName: undefined }),
        instance({ tag: "b", lastSeenAt: T0 + 100, displayName: "Studio" }),
      ],
      "user-1",
    );
    expect(rec!.lastSeenAtAtRev).toBe(T0 + 100);
    expect(rec!.displayName).toBe("Studio");
    expect(rec!.instances.map((i) => i.tag)).toEqual(["b", "a"]); // newest-first
  });
});

describe("listRecords helper", () => {
  it("returns live records and tombstones together", async () => {
    const storage = new FakeStorage();
    await upsertRecord(storage, COLL, "dev-A", devicePayload(), T0);
    await upsertRecord(storage, COLL, "dev-B", devicePayload({ deviceId: "dev-B" }), T0);
    await tombstoneRecord(storage, COLL, "dev-B", T0);
    const all = await listRecords<DeviceRecord>(storage, COLL);
    expect(all.length).toBe(2);
    expect(all.find((r) => r.id === "dev-B")!.deleted).toBe(true);
  });
});
