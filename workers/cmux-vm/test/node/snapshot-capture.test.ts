import { describe, expect, it } from "vitest";
import { newSnapshotId, newVmId } from "../../src/lib/ids.ts";
import { memoryLedgerStorage, TenantLedger } from "../../src/limits/ledger.ts";
import { type SnapshotCaptureCommand, type SnapshotCaptureIntent } from "../../src/limits/snapshot-capture.ts";

const fixture = () => {
  const storage = memoryLedgerStorage(), ledger = new TenantLedger(storage);
  const intent: SnapshotCaptureIntent = { id: newSnapshotId(), sourceVmId: newVmId(), displayName: null,
    labels: {}, createdBy: "key:owner", createdAt: "2026-10-18T00:00:00Z", ttlSeconds: null, autoDeleteSeconds: null };
  const run = (command: SnapshotCaptureCommand, now = 1) => ledger.snapshotCapture(command, now);
  const begin = () => run({ op: "begin", key: "key", fingerprint: "capture", intent, nonce: "lease" });
  const prepare = async () => {
    await begin();
    await ledger.reserve("snapshot", 1, 0, 0, "slot");
    return run({ op: "prepare", id: intent.id, nonce: "lease", reservationId: "slot", probe: { context: "context", source: "source", stamp: "stamp" } });
  };
  return { storage, ledger, intent, run, begin, prepare };
};

describe("durable snapshot capture", () => {
  it("grants one send across retries, process reconstruction and the former TTL", async () => {
    const f = fixture(); await f.prepare();
    expect(await f.run({ op: "send", id: f.intent.id, token: "send" })).toMatchObject({ state: "record", granted: true });
    const resumed = new TenantLedger(f.storage);
    expect(await resumed.snapshotCapture({ op: "begin", key: "key", fingerprint: "capture", intent: { ...f.intent, id: newSnapshotId() }, nonce: "other" }, 90_000_000)).toMatchObject({ record: { state: "pending", intent: { id: f.intent.id } }, granted: false });
    expect(await resumed.snapshotCapture({ op: "send", id: f.intent.id, token: "other" }, 90_000_000)).toMatchObject({ granted: false });
    expect(await f.ledger.reserve("snapshot", 1, 0, 90_000_000, "another")).toEqual({ ok: false });
  });
  it("reopens only the exact rejected send and cannot reopen after cancellation", async () => {
    const f = fixture(); await f.prepare(); await f.run({ op: "send", id: f.intent.id, token: "send" });
    expect(await f.run({ op: "reject", id: f.intent.id, token: "different" })).toMatchObject({ granted: false });
    expect(await f.run({ op: "reject", id: f.intent.id, token: "send" })).toMatchObject({ granted: true });
    expect(await f.run({ op: "cancel", id: f.intent.id })).toMatchObject({ record: { state: "cancelled" } });
    expect(await f.run({ op: "send", id: f.intent.id, token: "late" })).toMatchObject({ granted: false });
    expect(await f.run({ op: "cancel", id: f.intent.id })).toMatchObject({ record: { state: "cancelled" } });
    expect(await f.ledger.reserve("snapshot", 1, 0, 2, "another")).toEqual({ ok: true, reservationId: "another" });
  });
  it("holds quota and fences commit while an unknown send is cancelling", async () => {
    const f = fixture(); await f.prepare(); await f.run({ op: "send", id: f.intent.id, token: "send" });
    await f.run({ op: "cancel", id: f.intent.id });
    expect(await f.run({ op: "commit", id: f.intent.id })).toMatchObject({ granted: false, record: { state: "cancelling" } });
    expect(await f.ledger.reserve("snapshot", 1, 0, 99_000_000, "another")).toEqual({ ok: false });
    await f.run({ op: "cancelled", id: f.intent.id });
    expect(await f.ledger.reserve("snapshot", 1, 0, 99_000_000, "another")).toMatchObject({ ok: true });
  });
  it("prevents a stale claimant from preparing a different capture", async () => {
    const f = fixture(); await f.begin();
    const reclaim = await f.run({ op: "begin", key: "key", fingerprint: "capture", intent: { ...f.intent, id: newSnapshotId() }, nonce: "new" }, 700_000);
    expect(reclaim).toMatchObject({ granted: true, record: { intent: { id: f.intent.id } } });
    await f.ledger.reserve("snapshot", 1, 0, 700_000, "slot");
    expect(await f.run({ op: "prepare", id: f.intent.id, nonce: "lease", reservationId: "slot", probe: { context: "context", source: "source", stamp: "stamp" } }, 700_001)).toMatchObject({ granted: false });
  });
  it("quarantines a matching legacy claim and never sends it again", async () => {
    const f = fixture(); await f.ledger.begin("key", "capture", 0);
    expect(await f.run({ op: "begin", key: "key", fingerprint: "capture", intent: f.intent, nonce: "new" }, 99_000_000)).toEqual({ state: "legacy" });
    await f.ledger.begin("sweep", "different", 200_000_000);
    expect(await f.run({ op: "inspect", key: "key" })).toEqual({ state: "legacy" });
    await expect(f.ledger.begin("key", "capture", 200_000_000)).rejects.toThrow("unrecognized");
  });
  it("commits a single identity permanently and lists newest captures without leaking key digests", async () => {
    const f = fixture(); await f.prepare(); await f.run({ op: "send", id: f.intent.id, token: "send" });
    await f.run({ op: "commit", id: f.intent.id });
    const next = { ...f.intent, id: newSnapshotId() };
    await f.run({ op: "begin", key: "next", fingerprint: "next", intent: next, nonce: "next" }, 10);
    const first = await f.run({ op: "list", limit: 1 });
    expect(first).toMatchObject({ state: "page", items: [{ intent: { id: next.id } }] });
    if (first.state !== "page" || first.nextCursor === null) throw new Error("page missing");
    expect(await f.run({ op: "list", limit: 1, cursor: first.nextCursor })).toMatchObject({ items: [{ intent: { id: f.intent.id }, state: "committed" }], nextCursor: null });
    expect(await f.run({ op: "begin", key: "key", fingerprint: "capture", intent: next, nonce: "late" }, 99_000_000)).toMatchObject({ record: { state: "committed", intent: { id: f.intent.id } } });
  });
});
