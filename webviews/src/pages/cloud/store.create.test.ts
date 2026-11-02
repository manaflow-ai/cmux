// The create sheet's snapshot list (hq#4554): a failed `cloud.snapshot.list` stays on the draft
// as a failure with Retry, never as an empty list, and Retry keeps the draft.
import { describe, expect, test } from "bun:test";
import { MockCloudProvider } from "./mockProvider";
import { ACTION_RUN, CloudOps } from "./ops";
import { CloudStore } from "./store";

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function started(provider = new MockCloudProvider()) {
  let key = 0;
  const store = new CloudStore(provider, { newKey: () => `key_${++key}` });
  const unsubscribe = store.subscribe(() => undefined);
  await flush();
  await flush();
  return { store, provider, unsubscribe };
}

const listCalls = (provider: MockCloudProvider) =>
  provider.calls.filter((call) => call.op === CloudOps.snapshotList).length;
const creates = (provider: MockCloudProvider) =>
  provider.calls.filter(
    (call) => call.op === ACTION_RUN && (call.params as { action?: string }).action === CloudOps.machineCreate,
  ).length;

describe("Cloud create sheet: snapshot list", () => {
  test("a failed list is a failure on the draft, not an empty list; Retry reloads it and keeps the draft", async () => {
    const { store, provider, unsubscribe } = await started();
    provider.failNext = CloudOps.snapshotList;
    store.openCreate();
    const key = store.getSnapshot().create!.key;
    store.updateDraft({ name: "build box", memoryMb: 8192 });
    await flush();
    const failed = store.getSnapshot().create!;
    expect(failed.snapshotsFailed).toBe(true);
    expect(failed.snapshots).toBeUndefined();
    expect(failed.name).toBe("build box");

    const before = listCalls(provider);
    store.retrySnapshots();
    expect(store.getSnapshot().create!.snapshotsFailed).toBeUndefined();
    await flush();
    const draft = store.getSnapshot().create!;
    expect(listCalls(provider)).toBe(before + 1);
    expect(draft.snapshotsFailed).toBeUndefined();
    expect(draft.snapshots?.map((s) => s.id)).toEqual(provider.snapshots.map((s) => s.id));
    expect(draft.snapshots!.length).toBeGreaterThan(0);
    // Same sheet: name, size and the create's idempotency key are kept, and nothing was created.
    expect(draft.key).toBe(key);
    expect(draft.name).toBe("build box");
    expect(draft.memoryMb).toBe(8192);
    expect(creates(provider)).toBe(0);
    unsubscribe();
  });

  test("an empty list is empty, not a failure", async () => {
    const provider = new MockCloudProvider();
    provider.snapshots = [];
    const { store, unsubscribe } = await started(provider);
    store.openCreate();
    await flush();
    expect(store.getSnapshot().create!.snapshots).toEqual([]);
    expect(store.getSnapshot().create!.snapshotsFailed).toBeUndefined();
    unsubscribe();
  });

  test("an owner that serves no snapshot list offers Base image only, with no failure", async () => {
    const { store, unsubscribe } = await started(new MockCloudProvider({ unsupported: [CloudOps.snapshotList] }));
    store.openCreate();
    await flush();
    expect(store.getSnapshot().create!.snapshots).toEqual([]);
    expect(store.getSnapshot().create!.snapshotsFailed).toBeUndefined();
    unsubscribe();
  });

  test("Retry does nothing unless the list failed; an answer for a closed sheet lands on no newer one", async () => {
    const { store, provider, unsubscribe } = await started();
    store.openCreate();
    await flush();
    const before = listCalls(provider);
    store.retrySnapshots();
    expect(listCalls(provider)).toBe(before);

    store.closeCreate();
    provider.failNext = CloudOps.snapshotList;
    store.openCreate();
    const first = store.getSnapshot().create!.key;
    store.closeCreate();
    store.openCreate();
    await flush();
    const second = store.getSnapshot().create!;
    expect(second.key).not.toBe(first);
    // The first sheet's failure did not mark the second.
    expect(second.snapshotsFailed).toBeUndefined();
    expect(second.snapshots!.length).toBeGreaterThan(0);
    unsubscribe();
  });
});
