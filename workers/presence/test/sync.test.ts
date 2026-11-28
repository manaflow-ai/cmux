import { describe, expect, it } from "bun:test";
import {
  buildDelta,
  makeRecord,
  makeTombstone,
  pageSnapshot,
  parseHello,
  resolveHello,
  shouldGcTombstone,
  SNAPSHOT_PAGE_SIZE,
  SYNC_PROTOCOL,
  SYNC_SCHEMA_VERSION,
  TOMBSTONE_RETENTION_MS,
  type SyncRecord,
} from "../src/sync";

const T0 = 1_750_000_000_000;

function rec(id: string, rev: number, payload: unknown = { v: id }): SyncRecord {
  return makeRecord(id, rev, T0, payload);
}

describe("parseHello", () => {
  it("parses a well-formed hello and floors cursors", () => {
    const hello = parseHello({
      type: "sync.hello",
      protocol: SYNC_PROTOCOL,
      collections: [{ name: "devices", cursor: 12.9 }],
    });
    expect(hello).not.toBeNull();
    expect(hello!.collections).toEqual([{ name: "devices", cursor: 12, epoch: 0 }]);
  });

  it("parses the optional epoch", () => {
    const hello = parseHello({
      type: "sync.hello",
      protocol: SYNC_PROTOCOL,
      collections: [{ name: "devices", cursor: 5, epoch: 1718312400000 }],
    });
    expect(hello!.collections).toEqual([{ name: "devices", cursor: 5, epoch: 1718312400000 }]);
  });

  it("returns null for non-hello messages (DO ignores unknown types)", () => {
    expect(parseHello({ type: "online" })).toBeNull();
    expect(parseHello({ type: "sync.hello" })).toBeNull(); // missing fields
    expect(parseHello(null)).toBeNull();
    expect(parseHello("nope")).toBeNull();
  });

  it("drops malformed collection entries and defaults bad cursors to 0", () => {
    const hello = parseHello({
      type: "sync.hello",
      protocol: SYNC_PROTOCOL,
      collections: [
        { name: "", cursor: 5 }, // empty name dropped
        { name: "devices", cursor: -3 }, // negative -> 0
        { name: "workspaces", cursor: "x" }, // non-number -> 0
        42, // not an object, skipped
      ],
    });
    expect(hello!.collections).toEqual([
      { name: "devices", cursor: 0, epoch: 0 },
      { name: "workspaces", cursor: 0, epoch: 0 },
    ]);
  });

  it("bounds the collection list", () => {
    const many = Array.from({ length: 100 }, (_, i) => ({ name: `c${i}`, cursor: 0 }));
    const hello = parseHello(
      { type: "sync.hello", protocol: SYNC_PROTOCOL, collections: many },
      8,
    );
    expect(hello!.collections.length).toBe(8);
  });

  it("dedups repeated collection names, keeping the first (no DoS amplification)", () => {
    // A hello that repeats `devices` many times must collapse to ONE entry so it
    // cannot amplify into N backfill checks + N snapshot serializations downstream.
    const dupes = Array.from({ length: 16 }, (_, i) => ({ name: "devices", cursor: i }));
    const hello = parseHello({
      type: "sync.hello",
      protocol: SYNC_PROTOCOL,
      collections: [...dupes, { name: "workspaces", cursor: 7 }],
    });
    expect(hello!.collections).toEqual([
      { name: "devices", cursor: 0, epoch: 0 }, // first occurrence (cursor 0) kept
      { name: "workspaces", cursor: 7, epoch: 0 },
    ]);
  });
});

describe("resolveHello (snapshot vs delta floor)", () => {
  it("always forces a snapshot for a first-time client (cursor 0)", () => {
    // A cursor-0 client has nothing: it needs the paged snapshot + reconciliation,
    // not a catch-up delta, even when the GC floor is 0 (DESIGN.md §3.5).
    expect(resolveHello({ cursor: 0, gcFloor: 0, head: 10 })).toEqual({ mode: "snapshot" });
    expect(resolveHello({ cursor: 0, gcFloor: 4, head: 10 })).toEqual({ mode: "snapshot" });
    // Even with an empty collection (head 0), cursor 0 is a snapshot.
    expect(resolveHello({ cursor: 0, gcFloor: 0, head: 0 })).toEqual({ mode: "snapshot" });
  });

  it("delta-catches-up a client at or above the GC floor", () => {
    expect(resolveHello({ cursor: 7, gcFloor: 4, head: 10 })).toEqual({
      mode: "delta",
      sinceRev: 7,
    });
    expect(resolveHello({ cursor: 4, gcFloor: 4, head: 10 })).toEqual({
      mode: "delta",
      sinceRev: 4,
    });
  });

  it("forces a snapshot for a client below the GC floor (may have missed a deletion)", () => {
    expect(resolveHello({ cursor: 3, gcFloor: 4, head: 10 })).toEqual({ mode: "snapshot" });
  });

  it("forces a snapshot for a client whose cursor is AHEAD of head (storage reset/rollback)", () => {
    // A cursor above head cannot come from this DO's current history; delta mode
    // would send nothing and leave stale devices forever. Force a resnapshot.
    expect(resolveHello({ cursor: 12, gcFloor: 0, head: 10 })).toEqual({ mode: "snapshot" });
    // cursor == head is current (delta mode, empty catch-up).
    expect(resolveHello({ cursor: 10, gcFloor: 0, head: 10 })).toEqual({ mode: "delta", sinceRev: 10 });
  });

  it("forces a snapshot on an epoch mismatch even when the cursor looks current", () => {
    // Equal-head-after-reset: a new history coincidentally at the same head as
    // the client's cached old history. Without the epoch this would be a no-op
    // delta and stale devices would survive; the epoch mismatch forces a reset.
    expect(resolveHello({ cursor: 2, gcFloor: 0, head: 2, clientEpoch: 100, serverEpoch: 200 }))
      .toEqual({ mode: "snapshot" });
    // Matching epoch with a current cursor stays a delta.
    expect(resolveHello({ cursor: 2, gcFloor: 0, head: 2, clientEpoch: 200, serverEpoch: 200 }))
      .toEqual({ mode: "delta", sinceRev: 2 });
    // A first-time client (epoch 0) against an established server is a snapshot
    // anyway via the cursor-0 rule, but the epoch guard also covers a nonzero
    // cursor with a zero client epoch (pre-epoch cache) against a real server.
    expect(resolveHello({ cursor: 2, gcFloor: 0, head: 2, clientEpoch: 0, serverEpoch: 200 }))
      .toEqual({ mode: "snapshot" });
  });
});

describe("pageSnapshot", () => {
  it("emits one complete empty page for an empty collection (commits cursor)", () => {
    const pages = pageSnapshot("devices", 5, []);
    expect(pages).toHaveLength(1);
    expect(pages[0]).toMatchObject({ snapshotRev: 5, records: [], complete: true });
  });

  it("emits a single complete page when records fit", () => {
    const records = [rec("a", 1), rec("b", 2)];
    const pages = pageSnapshot("devices", 2, records, 10);
    expect(pages).toHaveLength(1);
    expect(pages[0]!.complete).toBe(true);
    expect(pages[0]!.snapshotRev).toBe(2);
    expect(pages[0]!.records.map((r) => r.id)).toEqual(["a", "b"]);
  });

  it("pages large snapshots; only the last page is complete; all share snapshotRev", () => {
    const records = Array.from({ length: 5 }, (_, i) => rec(`r${i}`, i + 1));
    const pages = pageSnapshot("devices", 9, records, 2);
    expect(pages.map((p) => p.records.length)).toEqual([2, 2, 1]);
    expect(pages.map((p) => p.complete)).toEqual([false, false, true]);
    expect(pages.every((p) => p.snapshotRev === 9)).toBe(true);
  });

  it("defaults to SNAPSHOT_PAGE_SIZE", () => {
    const records = Array.from({ length: SNAPSHOT_PAGE_SIZE + 1 }, (_, i) => rec(`r${i}`, i + 1));
    const pages = pageSnapshot("devices", SNAPSHOT_PAGE_SIZE + 1, records);
    expect(pages).toHaveLength(2);
  });
});

describe("buildDelta", () => {
  it("carries the head rev the frame advances the client to", () => {
    const frame = buildDelta("devices", 18, [rec("a", 18)]);
    expect(frame).toMatchObject({ type: "sync.delta", collection: "devices", rev: 18 });
    expect(frame.records).toHaveLength(1);
  });
});

describe("record stamping", () => {
  it("stamps live records with the current schema version", () => {
    const r = makeRecord("a", 3, T0, { hi: 1 });
    expect(r).toEqual({
      id: "a",
      rev: 3,
      updatedAt: T0,
      deleted: false,
      schemaVersion: SYNC_SCHEMA_VERSION,
      payload: { hi: 1 },
    });
  });

  it("stamps tombstones with an empty payload and deleted=true", () => {
    const t = makeTombstone("a", 9, T0);
    expect(t).toMatchObject({ id: "a", rev: 9, deleted: true, payload: {} });
    expect(t.schemaVersion).toBe(SYNC_SCHEMA_VERSION);
  });
});

describe("shouldGcTombstone", () => {
  it("never GCs a live record", () => {
    expect(shouldGcTombstone(makeRecord("a", 1, T0, {}), T0 + TOMBSTONE_RETENTION_MS * 2)).toBe(false);
  });

  it("GCs a tombstone past the retention window, not before", () => {
    const t = makeTombstone("a", 1, T0);
    expect(shouldGcTombstone(t, T0 + TOMBSTONE_RETENTION_MS - 1)).toBe(false);
    expect(shouldGcTombstone(t, T0 + TOMBSTONE_RETENTION_MS)).toBe(true);
  });
});
