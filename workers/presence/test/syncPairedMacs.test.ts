// Tests for the per-user paired-Mac backup collection (the first client-owned
// sync collection). Uses the same Map-backed `SyncStorage` fake as
// syncStorage.test.ts — no Workers runtime. Covers: parse bounds, per-user
// physical scoping (one user can't read another's hosts), the per-user cap,
// frame relabeling to the logical name, tombstones, and no-op idempotency.

import { describe, expect, it } from "bun:test";
import {
  applyBackupOps,
  listBackupSnapshot,
  listBackupSnapshotWithUnscopedFallback,
  listLiveBackup,
  MAX_BACKUP_OPS,
  MAX_CLIENT_SCOPE_LENGTH,
  MAX_PAIRED_MAC_CLIENT_SCOPES_PER_USER,
  MAX_PAIRED_MAC_RECORDS_PER_USER,
  MAX_PAIRED_MACS_PER_USER,
  normalizeClientScope,
  PairedMacBackupApplyError,
  pairedMacsCollection,
  PAIRED_MACS_COLLECTION,
  PAIRED_MACS_COLLECTION_TOMBSTONE_PREFIXES,
  parsePairedMacBackup,
  type PairedMacBackupRecord,
} from "../src/syncPairedMacs";
import {
  buildSnapshotPages,
  gcTombstones,
  listRecords,
  listTombstonedCollections,
  type SyncStorage,
} from "../src/syncStorage";

const T0 = 1_750_000_000_000;

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

function record(macDeviceID: string, host: string, port: number): PairedMacBackupRecord {
  return {
    macDeviceID,
    displayName: "Studio",
    routes: [{ id: "manual", kind: "tailscale", endpoint: { type: "host_port", host, port }, priority: 0 }],
    createdAt: T0,
    lastSeenAt: T0,
    isActive: true,
  };
}

describe("parsePairedMacBackup", () => {
  it("accepts a well-formed upsert + delete batch", () => {
    const parsed = parsePairedMacBackup({
      ops: [
        { macDeviceID: "manual-192.168.1.50:22", record: record("manual-192.168.1.50:22", "192.168.1.50", 22) },
        { macDeviceID: "gone", deleted: true },
      ],
    });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.ops).toHaveLength(2);
    expect(parsed.ops[0]).toMatchObject({ kind: "upsert", id: "manual-192.168.1.50:22" });
    expect(parsed.ops[1]).toEqual({ kind: "delete", id: "gone" });
  });

  it("rejects a non-array ops, missing id, and bad timestamps", () => {
    expect(parsePairedMacBackup({ ops: "nope" }).ok).toBe(false);
    expect(parsePairedMacBackup({ ops: [{ record: record("x", "h", 1) }] }).ok).toBe(false);
    expect(
      parsePairedMacBackup({ ops: [{ macDeviceID: "x", record: { ...record("x", "h", 1), lastSeenAt: "nope" } }] }).ok,
    ).toBe(false);
  });

  it("bounds the ops count", () => {
    const ops = Array.from({ length: MAX_PAIRED_MACS_PER_USER + 1 }, (_, i) => ({
      macDeviceID: `m${i}`,
      record: record(`m${i}`, "10.0.0.1", 22),
    }));
    expect(parsePairedMacBackup({ ops }).ok).toBe(false);
  });

  it("drops malformed route entries but keeps the record", () => {
    const parsed = parsePairedMacBackup({
      ops: [{ macDeviceID: "x", record: { ...record("x", "h", 1), routes: [null, 5, { id: "ok" }] } }],
    });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    const op = parsed.ops[0];
    if (op?.kind !== "upsert") throw new Error("expected an upsert op");
    expect(op.record.routes).toEqual([{ id: "ok" }]);
  });
});

describe("applyBackupOps", () => {
  it("normalizes optional client scopes into separate per-user collections", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: "mac-a", record: record("mac-a", "10.0.0.1", 22) }],
      T0,
      "ios:Feature Tag",
    );
    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: "mac-b", record: record("mac-b", "10.0.0.2", 22) }],
      T0,
      "ios:other",
    );

    expect(normalizeClientScope(" ios:Feature Tag ")).toBe("b64_aW9zOkZlYXR1cmUgVGFn");
    expect(pairedMacsCollection("user-1", "ios:Feature Tag")).toBe(
      "pairedMacsScoped:user-1:b64_aW9zOkZlYXR1cmUgVGFn",
    );
    expect((await listBackupSnapshot(storage, "user-1", "ios:Feature Tag")).records.map((r) => r.macDeviceID)).toEqual(["mac-a"]);
    expect((await listBackupSnapshot(storage, "user-1", "ios:other")).records.map((r) => r.macDeviceID)).toEqual(["mac-b"]);
    expect((await listBackupSnapshot(storage, "user-1")).records).toEqual([]);
  });

  it("rejects over-limit client scopes instead of rewriting them", () => {
    expect(normalizeClientScope(`ios:${"x".repeat(MAX_CLIENT_SCOPE_LENGTH)}`)).toBeNull();
  });

  it("bounds client-created scoped collections per user", async () => {
    const storage = new FakeStorage();
    for (let i = 0; i < MAX_PAIRED_MAC_CLIENT_SCOPES_PER_USER; i += 1) {
      const deltas = await applyBackupOps(
        storage,
        "user-1",
        [{ kind: "upsert", id: `mac-${i}`, record: record(`mac-${i}`, "10.0.0.1", 22) }],
        T0 + i,
        `ios:tag-${i}`,
      );
      expect(deltas).toHaveLength(1);
    }

    let overError: unknown;
    try {
      await applyBackupOps(
        storage,
        "user-1",
        [{ kind: "upsert", id: "blocked", record: record("blocked", "10.0.0.2", 22) }],
        T0 + 1000,
        "ios:blocked",
      );
    } catch (error) {
      overError = error;
    }
    expect(overError).toBeInstanceOf(PairedMacBackupApplyError);
    expect((overError as PairedMacBackupApplyError).code).toBe("too_many_client_scopes");
    expect((await listBackupSnapshot(storage, "user-1", "ios:blocked")).records).toEqual([]);

    const existingScopeUpdate = await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: "mac-0", record: record("mac-0", "10.0.0.9", 22) }],
      T0 + 2000,
      "ios:tag-0",
    );
    expect(existingScopeUpdate.length).toBeGreaterThan(0);
    expect((await listBackupSnapshot(storage, "user-1", "ios:tag-0")).records.map((r) => r.macDeviceID)).toEqual([
      "mac-0",
    ]);
  });

  it("writes the per-user physical collection and relabels frames to the logical name", async () => {
    const storage = new FakeStorage();
    const deltas = await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: "mac-a", record: record("mac-a", "192.168.1.50", 22) }],
      T0,
    );
    expect(deltas).toHaveLength(1);
    // The wire frame carries the LOGICAL name, never the user-id suffix.
    expect(deltas[0]?.collection).toBe(PAIRED_MACS_COLLECTION);
    // Storage is under the per-user PHYSICAL collection.
    const stored = await listRecords<PairedMacBackupRecord>(storage, pairedMacsCollection("user-1"));
    expect(stored.map((r) => r.id)).toEqual(["mac-a"]);
  });

  it("isolates users: user-2 never sees user-1's hosts", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "mac-a", record: record("mac-a", "10.0.0.1", 22) }], T0);
    await applyBackupOps(storage, "user-2", [{ kind: "upsert", id: "mac-b", record: record("mac-b", "10.0.0.2", 22) }], T0);

    const u1 = await buildSnapshotPages<PairedMacBackupRecord>(storage, pairedMacsCollection("user-1"));
    const u2 = await buildSnapshotPages<PairedMacBackupRecord>(storage, pairedMacsCollection("user-2"));
    const ids = (pages: typeof u1.pages) => pages.flatMap((p) => p.records.map((r) => r.id));
    expect(ids(u1.pages)).toEqual(["mac-a"]);
    expect(ids(u2.pages)).toEqual(["mac-b"]);
  });

  it("is a no-op when only the timestamp drifts (shape-equality, no rev churn)", async () => {
    const storage = new FakeStorage();
    const rec = record("mac-a", "192.168.1.50", 22);
    const first = await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "mac-a", record: rec }], T0);
    expect(first).toHaveLength(1);
    // Same shape (routes/name/active), only lastSeenAt advanced: must NOT churn.
    const drift = { ...rec, lastSeenAt: rec.lastSeenAt + 60_000 };
    const second = await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "mac-a", record: drift }], T0 + 1000);
    expect(second).toHaveLength(0);
    // ...but the stored freshness DOES advance in place (no rev/delta), so the iOS
    // LWW restore treats a republish of the same live route as fresh instead of
    // skipping the backup and keeping a stale local route.
    const afterDrift = await listLiveBackup(storage, "user-1");
    expect(afterDrift.find((r) => r.macDeviceID === "mac-a")?.lastSeenAt).toBe(drift.lastSeenAt);
    // A real route change DOES produce a delta.
    const changed = await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "mac-a", record: record("mac-a", "192.168.1.99", 22) }], T0 + 2000);
    expect(changed).toHaveLength(1);
  });

  it("active upserts clear previously active backed-up Macs for that user", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: "mac-a", record: record("mac-a", "10.0.0.1", 22) }],
      T0,
    );
    const deltas = await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: "mac-b", record: { ...record("mac-b", "10.0.0.2", 22), lastSeenAt: T0 + 1000 } }],
      T0 + 1000,
    );

    expect(deltas).toHaveLength(2);
    const live = await listLiveBackup(storage, "user-1");
    expect(live.filter((r) => r.isActive).map((r) => r.macDeviceID)).toEqual(["mac-b"]);
    expect(live.find((r) => r.macDeviceID === "mac-a")?.isActive).toBe(false);
  });

  it("a customization-only change syncs (not a same-shape no-op)", async () => {
    const storage = new FakeStorage();
    const base = record("mac-a", "10.0.0.1", 22);
    const first = await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "mac-a", record: base }], T0);
    expect(first).toHaveLength(1);
    // Same routes/name/active but a NEW custom name: must mint a delta so the
    // user's other devices receive the rename.
    const renamed = { ...base, customName: "Studio at home", lastSeenAt: base.lastSeenAt + 1000 };
    const second = await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "mac-a", record: renamed }], T0 + 1000);
    expect(second).toHaveLength(1);
    const live = await listLiveBackup(storage, "user-1");
    expect(live.find((r) => r.macDeviceID === "mac-a")?.customName).toBe("Studio at home");
  });

  it("a Mac route-publish (no custom keys) preserves iOS-set customizations", async () => {
    const storage = new FakeStorage();
    // iOS sets a name/color/icon (all custom keys provided -> authoritative).
    const set = {
      ...record("mac-a", "10.0.0.1", 22),
      customName: "Studio",
      customColor: "palette:3",
      customIcon: "🛠️",
    };
    await applyBackupOps(
      storage,
      "user-1",
      [
        {
          kind: "upsert",
          id: "mac-a",
          record: set,
          providedCustom: { name: true, color: true, icon: true },
        },
      ],
      T0,
    );

    // The Mac then republishes a NEW route, carrying NO custom keys. This must NOT
    // wipe the customizations (the regression: a heartbeat clobbering name/color/icon).
    const macPublish = {
      ...record("mac-a", "10.0.0.99", 22),
      customName: undefined,
      customColor: undefined,
      customIcon: undefined,
    };
    await applyBackupOps(
      storage,
      "user-1",
      [
        {
          kind: "upsert",
          id: "mac-a",
          record: macPublish,
          providedCustom: { name: false, color: false, icon: false },
        },
      ],
      T0 + 1000,
    );

    const afterMac = (await listLiveBackup(storage, "user-1")).find((r) => r.macDeviceID === "mac-a");
    expect(afterMac?.customName).toBe("Studio");
    expect(afterMac?.customColor).toBe("palette:3");
    expect(afterMac?.customIcon).toBe("🛠️");
    // ...and the new route from the Mac DID apply.
    expect(afterMac?.routes).toEqual(macPublish.routes);

    // An iOS reset-to-Auto (key PRESENT, value empty/undefined) DOES clear it.
    const cleared = {
      ...record("mac-a", "10.0.0.99", 22),
      customName: undefined,
      customColor: undefined,
      customIcon: undefined,
    };
    await applyBackupOps(
      storage,
      "user-1",
      [
        {
          kind: "upsert",
          id: "mac-a",
          record: cleared,
          providedCustom: { name: true, color: true, icon: true },
        },
      ],
      T0 + 2000,
    );
    const afterClear = (await listLiveBackup(storage, "user-1")).find((r) => r.macDeviceID === "mac-a");
    expect(afterClear?.customName).toBeUndefined();
    expect(afterClear?.customColor).toBeUndefined();
    expect(afterClear?.customIcon).toBeUndefined();
  });

  it("caps cumulative live+tombstone records so create/delete churn can't grow storage", async () => {
    const storage = new FakeStorage();
    const account = "user-churn";
    // Churn distinct ids (create then delete → tombstone) up to the cumulative cap.
    const cap = MAX_PAIRED_MAC_RECORDS_PER_USER;
    let created = 0;
    while (created < cap) {
      const batch = Math.min(MAX_BACKUP_OPS, cap - created);
      const upserts = Array.from({ length: batch }, (_, i) => ({
        kind: "upsert" as const,
        id: `mac-${created + i}`,
        record: record(`mac-${created + i}`, "10.0.0.1", 22),
      }));
      await applyBackupOps(storage, account, upserts, T0);
      await applyBackupOps(
        storage, account, upserts.map((o) => ({ kind: "delete" as const, id: o.id })), T0 + 1);
      created += batch;
    }

    // At the cumulative cap (all tombstoned), a BRAND-NEW id is refused...
    await applyBackupOps(storage, account, [
      { kind: "upsert", id: "mac-overflow", record: record("mac-overflow", "10.0.0.9", 22) },
    ], T0 + 2);
    const afterOverflow = await listLiveBackup(storage, account);
    expect(afterOverflow.some((r) => r.macDeviceID === "mac-overflow")).toBe(false);

    // ...but EXPLICITLY reviving an existing tombstoned id is allowed (reuses its
    // slot, no growth).
    await applyBackupOps(storage, account, [
      {
        kind: "upsert",
        id: "mac-0",
        allowTombstoneRevive: true,
        record: { ...record("mac-0", "10.0.0.1", 22), lastSeenAt: T0 + 3 },
      },
    ], T0 + 3);
    const afterRevive = await listLiveBackup(storage, account);
    expect(afterRevive.some((r) => r.macDeviceID === "mac-0")).toBe(true);
  });

  it("per-user paired-Mac tombstones are discoverable and GC-able (no unbounded growth)", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "mac-a", record: record("mac-a", "192.168.1.50", 22) }], T0);
    await applyBackupOps(storage, "user-1", [{ kind: "delete", id: "mac-a" }], T0 + 1000);
    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: "scoped-mac", record: record("scoped-mac", "192.168.1.51", 22) }],
      T0,
      "ios:dev",
    );
    await applyBackupOps(storage, "user-1", [{ kind: "delete", id: "scoped-mac" }], T0 + 1000, "ios:dev");
    // The alarm discovers the per-user collection by tombstone prefix without
    // knowing the user id or iOS build scope ahead of time.
    const collection = pairedMacsCollection("user-1");
    const scopedCollection = pairedMacsCollection("user-1", "ios:dev");
    expect(await listTombstonedCollections(storage, `${PAIRED_MACS_COLLECTION}:`)).toContain(collection);
    expect(await listTombstonedCollections(storage, PAIRED_MACS_COLLECTION_TOMBSTONE_PREFIXES[1] ?? "")).toContain(
      scopedCollection,
    );
    // GC with retention elapsed collects the tombstone, so churned create/delete
    // cannot grow storage without bound.
    const res = await gcTombstones(storage, collection, T0 + 1_000_000_000, 0);
    expect(res.collected).toBe(1);
    const scopedRes = await gcTombstones(storage, scopedCollection, T0 + 1_000_000_000, 0);
    expect(scopedRes.collected).toBe(2);
    expect(await listTombstonedCollections(storage, `${PAIRED_MACS_COLLECTION}:`)).not.toContain(collection);
    expect(await listTombstonedCollections(storage, PAIRED_MACS_COLLECTION_TOMBSTONE_PREFIXES[1] ?? "")).not.toContain(
      scopedCollection,
    );
  });

  it("scoped restore falls back to unscoped Mac seed only until the scoped collection exists", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: "mac-seed", record: record("mac-seed", "192.168.1.50", 22) }],
      T0,
    );

    const emptyScoped = await listBackupSnapshotWithUnscopedFallback(storage, "user-1", "ios:dev");
    expect(emptyScoped.records.map((r) => r.macDeviceID)).toEqual(["mac-seed"]);

    await applyBackupOps(
      storage,
      "user-1",
      [
        {
          kind: "upsert",
          id: "scoped-mac",
          record: { ...record("scoped-mac", "192.168.1.51", 22), lastSeenAt: T0 + 1000 },
        },
      ],
      T0 + 1000,
      "ios:dev",
    );
    const nonEmptyScoped = await listBackupSnapshotWithUnscopedFallback(storage, "user-1", "ios:dev");
    expect(nonEmptyScoped.records.map((r) => r.macDeviceID)).toEqual(["scoped-mac", "mac-seed"]);

    await applyBackupOps(storage, "user-1", [{ kind: "delete", id: "scoped-mac" }], T0 + 2000, "ios:dev");
    const tombstonedScoped = await listBackupSnapshotWithUnscopedFallback(storage, "user-1", "ios:dev");
    expect(tombstonedScoped.records.map((r) => r.macDeviceID)).toEqual(["mac-seed"]);
    expect(tombstonedScoped.deletedMacDeviceIDs).toEqual(["scoped-mac"]);
  });

  it("first scoped write seeds untouched unscoped backup rows", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(
      storage,
      "user-1",
      [
        { kind: "upsert", id: "mac-a", record: record("mac-a", "192.168.1.50", 22) },
        {
          kind: "upsert",
          id: "mac-b",
          record: { ...record("mac-b", "192.168.1.51", 22), lastSeenAt: T0 + 1 },
        },
      ],
      T0,
    );

    await applyBackupOps(
      storage,
      "user-1",
      [
        {
          kind: "upsert",
          id: "mac-a",
          record: { ...record("mac-a", "192.168.1.99", 22), lastSeenAt: T0 + 2 },
        },
      ],
      T0 + 2,
      "ios:dev",
    );

    const scoped = await listBackupSnapshotWithUnscopedFallback(storage, "user-1", "ios:dev");
    expect(scoped.records.map((r) => r.macDeviceID)).toEqual(["mac-a", "mac-b"]);
    expect(scoped.records.find((r) => r.macDeviceID === "mac-a")?.routes).toEqual(
      record("mac-a", "192.168.1.99", 22).routes,
    );
    expect(scoped.records.find((r) => r.macDeviceID === "mac-b")?.routes).toEqual(
      record("mac-b", "192.168.1.51", 22).routes,
    );
  });

  it("scoped delete of an unscoped fallback seed blocks future fallback restores", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: "mac-seed", record: record("mac-seed", "192.168.1.50", 22) }],
      T0,
    );

    expect(
      (await listBackupSnapshotWithUnscopedFallback(storage, "user-1", "ios:dev")).records.map((r) => r.macDeviceID),
    ).toEqual(["mac-seed"]);

    const deltas = await applyBackupOps(storage, "user-1", [{ kind: "delete", id: "mac-seed" }], T0 + 1000, "ios:dev");
    expect(deltas).toHaveLength(1);
    const afterDelete = await listBackupSnapshotWithUnscopedFallback(storage, "user-1", "ios:dev");
    expect(afterDelete.records).toEqual([]);
    expect(afterDelete.deletedMacDeviceIDs).toEqual(["mac-seed"]);

    await gcTombstones(storage, pairedMacsCollection("user-1", "ios:dev"), T0 + 1_000_000_000, 0);
    const afterGc = await listBackupSnapshotWithUnscopedFallback(storage, "user-1", "ios:dev");
    expect(afterGc.records).toEqual([]);
    expect(afterGc.deletedMacDeviceIDs).toEqual([]);
  });

  it("listLiveBackup returns live records newest-first and excludes tombstones, scoped per user", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(
      storage,
      "user-1",
      [
        { kind: "upsert", id: "old", record: { ...record("old", "10.0.0.1", 22), lastSeenAt: T0 } },
        { kind: "upsert", id: "new", record: { ...record("new", "10.0.0.2", 22), lastSeenAt: T0 + 5000 } },
        { kind: "upsert", id: "gone", record: record("gone", "10.0.0.3", 22) },
      ],
      T0,
    );
    await applyBackupOps(storage, "user-1", [{ kind: "delete", id: "gone" }], T0 + 6000);
    await applyBackupOps(storage, "user-2", [{ kind: "upsert", id: "other", record: record("other", "10.9.9.9", 22) }], T0);

    const list = await listLiveBackup(storage, "user-1");
    expect(list.map((r) => r.macDeviceID)).toEqual(["new", "old"]); // newest-first, tombstone excluded
    const otherList = await listLiveBackup(storage, "user-2");
    expect(otherList.map((r) => r.macDeviceID)).toEqual(["other"]); // isolated per user
  });

  it("listBackupSnapshot returns tombstones for restore", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "mac-a", record: record("mac-a", "10.0.0.1", 22) }], T0);
    await applyBackupOps(storage, "user-1", [{ kind: "delete", id: "mac-a" }], T0 + 1000);

    const snapshot = await listBackupSnapshot(storage, "user-1");
    expect(snapshot.records).toEqual([]);
    expect(snapshot.deletedMacDeviceIDs).toEqual(["mac-a"]);
  });

  it("ignores ordinary upserts after a retained tombstone unless explicitly revived", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "mac-a", record: record("mac-a", "10.0.0.1", 22) }], T0);
    await applyBackupOps(storage, "user-1", [{ kind: "delete", id: "mac-a" }], T0 + 1000);

    const staleWithFastClock = await applyBackupOps(storage, "user-1", [
      { kind: "upsert", id: "mac-a", record: { ...record("mac-a", "10.0.0.1", 22), lastSeenAt: T0 + 60_000 } },
    ], T0 + 2000);
    expect(staleWithFastClock).toHaveLength(0);
    expect((await listBackupSnapshot(storage, "user-1")).deletedMacDeviceIDs).toEqual(["mac-a"]);

    const explicitRevive = await applyBackupOps(storage, "user-1", [
      {
        kind: "upsert",
        id: "mac-a",
        allowTombstoneRevive: true,
        record: { ...record("mac-a", "10.0.0.2", 22), lastSeenAt: T0 + 3000 },
      },
    ], T0 + 3000);
    expect(explicitRevive).toHaveLength(1);
    expect((await listLiveBackup(storage, "user-1")).map((r) => r.macDeviceID)).toEqual(["mac-a"]);
  });

  it("tombstones a deleted host", async () => {
    const storage = new FakeStorage();
    await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "mac-a", record: record("mac-a", "10.0.0.1", 22) }], T0);
    const del = await applyBackupOps(storage, "user-1", [{ kind: "delete", id: "mac-a" }], T0 + 1000);
    expect(del).toHaveLength(1);
    expect(del[0]?.records[0]?.deleted).toBe(true);
    const live = (await listRecords<PairedMacBackupRecord>(storage, pairedMacsCollection("user-1"))).filter((r) => !r.deleted);
    expect(live).toHaveLength(0);
  });

  it("drops NEW records beyond the per-user cap but keeps updating existing ones", async () => {
    const storage = new FakeStorage();
    const ops = Array.from({ length: MAX_PAIRED_MACS_PER_USER }, (_, i) => ({
      kind: "upsert" as const,
      id: `m${i}`,
      record: record(`m${i}`, "10.0.0.1", 1024 + i),
    }));
    await applyBackupOps(storage, "user-1", ops, T0);
    const live = () =>
      listRecords<PairedMacBackupRecord>(storage, pairedMacsCollection("user-1")).then((r) =>
        r.filter((x) => !x.deleted),
      );
    expect((await live()).length).toBe(MAX_PAIRED_MACS_PER_USER);
    // One more NEW id is dropped (still at cap).
    const over = await applyBackupOps(storage, "user-1", [{ kind: "upsert", id: "extra", record: record("extra", "10.0.0.9", 22) }], T0 + 1000);
    expect(over).toHaveLength(0);
    expect((await live()).length).toBe(MAX_PAIRED_MACS_PER_USER);
    // But updating an EXISTING id still works.
    const upd = await applyBackupOps(
      storage,
      "user-1",
      [{ kind: "upsert", id: "m0", record: record("m0", "10.0.0.250", 2222) }],
      T0 + 2000,
    );
    expect(upd).toHaveLength(2);
    expect((await live()).filter((r) => r.payload.isActive).map((r) => r.id)).toEqual(["m0"]);
  });
});
