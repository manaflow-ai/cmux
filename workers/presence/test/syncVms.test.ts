// Tests for the backend-published Cloud machine list (`vms`) sync collection.
// Uses the same Map-backed `SyncStorage` fake as syncStorage.test.ts (no
// Workers runtime). Covers: parse bounds, out-of-order rejection by the source
// clock, `replace` tombstoning ids missing from the observed list (but not a
// machine created after the observation), idempotent no-op upserts, delete,
// tombstone GC, hello snapshot then delta, and the publisher auth check.

import { describe, expect, it } from "bun:test";
import {
  applyVmOps,
  MAX_VM_PUBLISH_OPS,
  MAX_VM_REPLACE_RECORDS,
  parseVmPublish,
  parseVmRecord,
  VMS_COLLECTION,
  vmShapeEqual,
  type VmRecord,
} from "../src/syncVms";
import {
  gcTombstones,
  listRecords,
  readBackfillDone,
  readGcFloor,
  readHead,
  readRecord,
  resolveHelloFrames,
  type SyncStorage,
} from "../src/syncStorage";
import { TOMBSTONE_RETENTION_MS } from "../src/sync";
import { isVmsPublisherAuthorized } from "../src/validate";

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

function vm(id: string, overrides: Partial<VmRecord> = {}): VmRecord {
  return {
    id,
    provider: "freestyle",
    status: "running",
    image: "devbox",
    imageVersion: "3",
    kind: "desktop",
    capabilities: { checkpoint: true, fork: false, attachTransports: ["ssh", "cmux-remote"] },
    createdAt: T0 - 60_000,
    displayName: null,
    slug: "sleepy-teal-otter",
    createdByUserId: "user-a",
    address: { ipv4: "10.0.0.5", ipv6: null },
    sourceUpdatedAtMs: T0,
    ...overrides,
  };
}

async function liveIds(storage: SyncStorage): Promise<string[]> {
  return (await listRecords<VmRecord>(storage, VMS_COLLECTION))
    .filter((r) => !r.deleted)
    .map((r) => r.id)
    .sort();
}

describe("parseVmPublish", () => {
  it("accepts upsert, delete and replace ops with a trusted team id", () => {
    const parsed = parseVmPublish({
      teamId: " team-1 ",
      ops: [
        { kind: "upsert", record: vm("vm-1") },
        { kind: "delete", id: "vm-2", sourceUpdatedAtMs: T0 },
        { kind: "replace", records: [vm("vm-1")], observedAtMs: T0 },
      ],
    });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.teamId).toBe("team-1");
    expect(parsed.ops.map((op) => op.kind)).toEqual(["upsert", "delete", "replace"]);
  });

  it("rejects a missing team id, unbounded ops and malformed records", () => {
    expect(parseVmPublish({ ops: [] })).toEqual({ ok: false, error: "invalid_team_id" });
    expect(parseVmPublish({ teamId: "t", ops: {} })).toEqual({ ok: false, error: "invalid_ops" });
    expect(parseVmPublish({
      teamId: "t",
      ops: Array.from({ length: MAX_VM_PUBLISH_OPS + 1 }, () => ({ kind: "delete", id: "x", sourceUpdatedAtMs: 1 })),
    })).toEqual({ ok: false, error: "too_many_ops" });
    expect(parseVmPublish({
      teamId: "t",
      ops: [{ kind: "replace", observedAtMs: 1, records: Array.from({ length: MAX_VM_REPLACE_RECORDS + 1 }, (_, i) => vm(`vm-${i}`)) }],
    })).toEqual({ ok: false, error: "too_many_records" });
    expect(parseVmPublish({ teamId: "t", ops: [{ kind: "upsert", record: { ...vm("vm-1"), id: "" } }] }))
      .toEqual({ ok: false, error: "invalid_id" });
    expect(parseVmPublish({ teamId: "t", ops: [{ kind: "upsert", record: { ...vm("vm-1"), sourceUpdatedAtMs: "now" } }] }))
      .toEqual({ ok: false, error: "invalid_timestamps" });
    expect(parseVmPublish({ teamId: "t", ops: [{ kind: "delete", id: "vm-1" }] }))
      .toEqual({ ok: false, error: "invalid_timestamps" });
    expect(parseVmPublish({ teamId: "t", ops: [{ kind: "replace", records: [vm("vm-1")] }] }))
      .toEqual({ ok: false, error: "invalid_timestamps" });
    expect(parseVmPublish({ teamId: "t", ops: [{ kind: "rename", id: "vm-1" }] }))
      .toEqual({ ok: false, error: "invalid_op_kind" });
    expect(parseVmPublish({ teamId: "t", ops: [{ kind: "upsert", record: { ...vm("vm-1"), capabilities: { a: "yes" } } }] }))
      .toEqual({ ok: false, error: "invalid_capabilities" });
    expect(parseVmPublish({ teamId: "t", ops: [{ kind: "upsert", record: { ...vm("vm-1"), address: "10.0.0.1" } }] }))
      .toEqual({ ok: false, error: "invalid_address" });
  });

  it("normalizes optional fields and drops unknown keys", () => {
    const parsed = parseVmRecord({ ...vm("vm-1"), displayName: "  ", address: undefined, extra: "ignored" });
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.record.displayName).toBeNull();
    expect(parsed.record.address).toEqual({ ipv4: null, ipv6: null });
    expect("extra" in parsed.record).toBe(false);
  });
});

describe("applyVmOps", () => {
  it("upserts a new machine and is a no-op for an unchanged republish", async () => {
    const storage = new FakeStorage();
    const first = await applyVmOps(storage, [{ kind: "upsert", record: vm("vm-1") }], T0);
    expect(first).toHaveLength(1);
    expect(first[0]?.collection).toBe(VMS_COLLECTION);
    expect(first[0]?.records[0]?.payload).toEqual(vm("vm-1"));
    // Same shape, newer clock: no rev, no delta, but the stored clock advances.
    const again = await applyVmOps(storage, [{ kind: "upsert", record: vm("vm-1", { sourceUpdatedAtMs: T0 + 5 }) }], T0 + 5);
    expect(again).toEqual([]);
    expect(await readHead(storage, VMS_COLLECTION)).toBe(1);
    const stored = await readRecord<VmRecord>(storage, VMS_COLLECTION, "vm-1");
    expect(stored?.payload.sourceUpdatedAtMs).toBe(T0 + 5);
  });

  it("rejects an upsert older than the stored row (out-of-order publishers)", async () => {
    const storage = new FakeStorage();
    await applyVmOps(storage, [{ kind: "upsert", record: vm("vm-1", { status: "paused", sourceUpdatedAtMs: T0 + 10 }) }], T0);
    const stale = await applyVmOps(storage, [{ kind: "upsert", record: vm("vm-1", { status: "running", sourceUpdatedAtMs: T0 }) }], T0 + 1);
    expect(stale).toEqual([]);
    const stored = await readRecord<VmRecord>(storage, VMS_COLLECTION, "vm-1");
    expect(stored?.payload.status).toBe("paused");
    // A newer change still lands and mints a rev.
    const newer = await applyVmOps(storage, [{ kind: "upsert", record: vm("vm-1", { status: "running", sourceUpdatedAtMs: T0 + 20 }) }], T0 + 2);
    expect(newer).toHaveLength(1);
    expect(newer[0]?.rev).toBe(2);
  });

  it("deletes with a tombstone that keeps rejecting older upserts", async () => {
    const storage = new FakeStorage();
    await applyVmOps(storage, [{ kind: "upsert", record: vm("vm-1") }], T0);
    const deleted = await applyVmOps(storage, [{ kind: "delete", id: "vm-1", sourceUpdatedAtMs: T0 + 10 }], T0 + 1);
    expect(deleted).toHaveLength(1);
    expect(deleted[0]?.records[0]?.deleted).toBe(true);
    expect(deleted[0]?.records[0]?.payload).toEqual({ sourceUpdatedAtMs: T0 + 10 });
    // Late, older upsert (a slow web instance): rejected.
    const late = await applyVmOps(storage, [{ kind: "upsert", record: vm("vm-1", { sourceUpdatedAtMs: T0 + 5 }) }], T0 + 2);
    expect(late).toEqual([]);
    expect(await liveIds(storage)).toEqual([]);
    // Older delete for the same id: no-op too (already a tombstone).
    const again = await applyVmOps(storage, [{ kind: "delete", id: "vm-1", sourceUpdatedAtMs: T0 }], T0 + 3);
    expect(again).toEqual([]);
  });

  it("tombstones a delete for a machine the DO never saw", async () => {
    const storage = new FakeStorage();
    const deltas = await applyVmOps(storage, [{ kind: "delete", id: "ghost", sourceUpdatedAtMs: T0 }], T0);
    expect(deltas).toHaveLength(1);
    expect((await readRecord(storage, VMS_COLLECTION, "ghost"))?.deleted).toBe(true);
  });

  it("replace tombstones ids missing from the observed list and marks the backfill", async () => {
    const storage = new FakeStorage();
    await applyVmOps(storage, [
      { kind: "upsert", record: vm("vm-1") },
      { kind: "upsert", record: vm("vm-2") },
      { kind: "upsert", record: vm("vm-3") },
    ], T0);
    expect(await readBackfillDone(storage, VMS_COLLECTION)).toBe(false);
    const deltas = await applyVmOps(storage, [{
      kind: "replace",
      records: [vm("vm-1"), vm("vm-2", { displayName: "Renamed", sourceUpdatedAtMs: T0 + 1 })],
      observedAtMs: T0 + 2,
    }], T0 + 3);
    // vm-1 unchanged (no delta), vm-2 renamed (delta), vm-3 tombstoned (delta).
    expect(deltas.map((d) => [d.records[0]?.id, d.records[0]?.deleted])).toEqual([
      ["vm-2", false],
      ["vm-3", true],
    ]);
    expect(await liveIds(storage)).toEqual(["vm-1", "vm-2"]);
    expect(await readBackfillDone(storage, VMS_COLLECTION)).toBe(true);
  });

  it("replace does not tombstone a machine created after the list was observed", async () => {
    const storage = new FakeStorage();
    // The list was read at T0+2; a create landed at T0+5 and its upsert reached
    // the DO before the list's after-response replace did.
    await applyVmOps(storage, [{ kind: "upsert", record: vm("vm-new", { sourceUpdatedAtMs: T0 + 5 }) }], T0 + 6);
    const deltas = await applyVmOps(storage, [{ kind: "replace", records: [vm("vm-1")], observedAtMs: T0 + 2 }], T0 + 7);
    expect(deltas.map((d) => d.records[0]?.id)).toEqual(["vm-1"]);
    expect(await liveIds(storage)).toEqual(["vm-1", "vm-new"]);
  });

  it("replace with an unchanged list mints no rev", async () => {
    const storage = new FakeStorage();
    await applyVmOps(storage, [{ kind: "replace", records: [vm("vm-1"), vm("vm-2")], observedAtMs: T0 }], T0);
    const head = await readHead(storage, VMS_COLLECTION);
    const deltas = await applyVmOps(storage, [{ kind: "replace", records: [vm("vm-2"), vm("vm-1")], observedAtMs: T0 + 60_000 }], T0 + 60_000);
    expect(deltas).toEqual([]);
    expect(await readHead(storage, VMS_COLLECTION)).toBe(head);
  });

  it("vmShapeEqual ignores only the source clock", () => {
    expect(vmShapeEqual(vm("a"), vm("a", { sourceUpdatedAtMs: 1 }))).toBe(true);
    expect(vmShapeEqual(vm("a"), vm("a", { status: "paused" }))).toBe(false);
    expect(vmShapeEqual(vm("a"), vm("a", { address: { ipv4: "10.0.0.6", ipv6: null } }))).toBe(false);
    expect(vmShapeEqual(vm("a"), vm("a", { capabilities: { checkpoint: false } }))).toBe(false);
  });
});

describe("tombstone GC", () => {
  it("removes an expired vms tombstone and raises the GC floor", async () => {
    const storage = new FakeStorage();
    await applyVmOps(storage, [{ kind: "upsert", record: vm("vm-1") }], T0);
    await applyVmOps(storage, [{ kind: "delete", id: "vm-1", sourceUpdatedAtMs: T0 + 1 }], T0 + 1);
    const early = await gcTombstones(storage, VMS_COLLECTION, T0 + 1 + TOMBSTONE_RETENTION_MS - 1);
    expect(early.collected).toBe(0);
    const late = await gcTombstones(storage, VMS_COLLECTION, T0 + 1 + TOMBSTONE_RETENTION_MS);
    expect(late.collected).toBe(1);
    expect(await readGcFloor(storage, VMS_COLLECTION)).toBe(2);
    expect(await readRecord(storage, VMS_COLLECTION, "vm-1")).toBeUndefined();
  });
});

describe("hello: snapshot then delta", () => {
  it("serves a full snapshot to a first-time client, then a catch-up delta", async () => {
    const storage = new FakeStorage();
    await applyVmOps(storage, [{ kind: "replace", records: [vm("vm-1"), vm("vm-2")], observedAtMs: T0 }], T0);
    const first = await resolveHelloFrames<VmRecord>(storage, VMS_COLLECTION, 0, undefined, 0, T0);
    expect(first.mode).toBe("snapshot");
    if (first.mode !== "snapshot") return;
    expect(first.snapshotRev).toBe(2);
    expect(first.pages).toHaveLength(1);
    expect(first.pages[0]?.complete).toBe(true);
    expect(first.pages[0]?.records.map((r) => r.id)).toEqual(["vm-1", "vm-2"]);

    await applyVmOps(storage, [
      { kind: "upsert", record: vm("vm-2", { status: "paused", sourceUpdatedAtMs: T0 + 1 }) },
      { kind: "delete", id: "vm-1", sourceUpdatedAtMs: T0 + 1 },
    ], T0 + 1);
    const second = await resolveHelloFrames<VmRecord>(storage, VMS_COLLECTION, first.snapshotRev, undefined, first.epoch, T0 + 2);
    expect(second.mode).toBe("delta");
    if (second.mode !== "delta") return;
    expect(second.delta?.rev).toBe(4);
    expect(second.delta?.records.map((r) => [r.id, r.deleted])).toEqual([["vm-2", false], ["vm-1", true]]);
    expect(second.delta?.records[0]?.payload).toMatchObject({ status: "paused" });
  });
});

describe("isVmsPublisherAuthorized", () => {
  const secret = "v".repeat(64);
  const request = (value?: string) => new Request("https://presence.example/v1/sync/vms", {
    method: "POST",
    headers: value ? { "x-cmux-vms-publisher-secret": value } : {},
  });

  it("requires the exact service secret and never a user bearer", async () => {
    expect(await isVmsPublisherAuthorized(request(secret), secret)).toBe(true);
    expect(await isVmsPublisherAuthorized(request("w".repeat(64)), secret)).toBe(false);
    expect(await isVmsPublisherAuthorized(request(), secret)).toBe(false);
    expect(await isVmsPublisherAuthorized(request(secret), undefined)).toBe(false);
    expect(await isVmsPublisherAuthorized(request("short"), "short")).toBe(false);
    expect(await isVmsPublisherAuthorized(request(`${secret}extra`), secret)).toBe(false);
    // The connectivity header is a different capability.
    const wrongHeader = new Request("https://presence.example/v1/sync/vms", {
      method: "POST",
      headers: { "x-cmux-connectivity-publisher-secret": secret },
    });
    expect(await isVmsPublisherAuthorized(wrongHeader, secret)).toBe(false);
  });
});
