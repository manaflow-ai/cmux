import { describe, expect, test } from "bun:test";
import { MockCloudProvider, sampleMachines, SERVER_GAPS } from "./mockProvider";
import { AccountOps, ACTION_RUN, CloudOps } from "./ops";
import { CloudStore } from "./store";

/** Lets queued promise callbacks run. */
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

async function started(provider = new MockCloudProvider()) {
  let keys = 0;
  const store = new CloudStore(provider, { newKey: () => `k${++keys}` });
  const unsubscribe = store.subscribe(() => undefined);
  await store.start();
  await settle();
  return { provider, store, unsubscribe };
}

const ops = (provider: MockCloudProvider, op: string) => provider.calls.filter((call) => call.op === op);
const machineOps = (provider: MockCloudProvider) =>
  provider.calls.filter((call) => call.op.startsWith("cmux.cloud.machine."));
const runs = (provider: MockCloudProvider) =>
  ops(provider, ACTION_RUN).map((call) => call.params as { action: string; args: Record<string, unknown> });
const running = () => sampleMachines().find((machine) => machine.status === "running" && !machine.classic)!;

describe("CloudStore", () => {
  test("signed in: reads auth, watches machines and lists them once", async () => {
    const { provider, store } = await started();
    const snap = store.getSnapshot();
    expect(snap.connection).toBe("connected");
    expect(snap.auth?.signedIn).toBe(true);
    expect(snap.rows.map((row) => row.id)).toEqual(sampleMachines().map((machine) => machine.id));
    expect(ops(provider, CloudOps.machineList).length).toBe(1);
    expect(provider.watchers).toBe(1);
  });

  test("a paged list follows next_cursor to the last page", async () => {
    const provider = new MockCloudProvider({ pageSize: 2 });
    const { store } = await started(provider);
    expect(ops(provider, CloudOps.machineList).map((call) => call.params)).toEqual([{}, { cursor: "cur_2" }]);
    expect(store.getSnapshot().rows.map((row) => row.id)).toEqual(sampleMachines().map((machine) => machine.id));
  });

  test("signed out: no machine op runs and no watch starts", async () => {
    const provider = new MockCloudProvider({ signedIn: false });
    const { store } = await started(provider);
    expect(store.getSnapshot().auth?.signedIn).toBe(false);
    expect(machineOps(provider)).toEqual([]);
    expect(provider.watchers).toBe(0);
  });

  test("sign in re-reads auth and then loads machines", async () => {
    const provider = new MockCloudProvider({ signedIn: false, unsupported: [] });
    const { store } = await started(provider);
    await store.signIn();
    await settle();
    expect(ops(provider, AccountOps.signIn)).toEqual([]);
    expect(runs(provider).map((run) => run.action)).toEqual([AccountOps.signIn]);
    expect(store.getSnapshot().auth?.signedIn).toBe(true);
    expect(store.getSnapshot().rows.length).toBe(sampleMachines().length);
  });

  test("a watch event updates the list without a refetch", async () => {
    const { provider, store } = await started();
    const lists = ops(provider, CloudOps.machineList).length;
    const target = sampleMachines()[0];
    provider.emitUpsert({ ...target, status: "paused" });
    await settle();
    expect(store.getSnapshot().rows.find((row) => row.id === target.id)?.status).toBe("paused");
    provider.emitUpsert({ id: "vm_new", status: "provisioning", name: "new-box", revision: "1" });
    await settle();
    expect(store.getSnapshot().rows.map((row) => row.id)).toContain("vm_new");
    provider.emitRemoved(target.id);
    await settle();
    expect(store.getSnapshot().rows.map((row) => row.id)).not.toContain(target.id);
    expect(ops(provider, CloudOps.machineList).length).toBe(lists);
  });

  test("an event older than the list revision is dropped", async () => {
    const { provider, store } = await started();
    const target = sampleMachines()[0];
    provider.emitRaw({ type: "upsert", revision: 1, machine: { ...target, status: "failed" } });
    await settle();
    expect(store.getSnapshot().rows.find((row) => row.id === target.id)?.status).toBe(target.status);
  });

  test("the new statuses show as sent; an unknown one shows as unknown", async () => {
    const { provider, store } = await started();
    for (const status of ["starting", "pausing", "deleting"] as const) {
      provider.emitUpsert({ ...sampleMachines()[0], status });
      await settle();
      expect(store.getSnapshot().rows[0].status).toBe(status);
    }
    provider.emitUpsert({ ...sampleMachines()[0], status: "hibernating" as never });
    await settle();
    expect(store.getSnapshot().rows[0].status).toBe("unknown");
  });

  test("create runs as a native action with one key on a double submit", async () => {
    const { provider, store } = await started();
    store.openCreate();
    store.updateDraft({ name: "build-box" });
    await Promise.all([store.submitCreate(), store.submitCreate()]);
    await settle();
    expect(ops(provider, CloudOps.machineCreate)).toEqual([]);
    const creates = runs(provider).filter((run) => run.action === CloudOps.machineCreate);
    expect(creates.length).toBe(1);
    expect(creates[0].args).toEqual({ name: "build-box", size: { memory_mb: 4096 }, idempotency_key: "k1" });
    expect(store.getSnapshot().create).toBeUndefined();
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().rows.some((row) => row.title === "build-box")).toBe(true);
  });

  test("a create retried after a transport failure reuses the same key", async () => {
    const { provider, store } = await started();
    store.openCreate();
    store.updateDraft({ name: "retry-box" });
    provider.failNext = ACTION_RUN;
    await store.submitCreate();
    expect(store.getSnapshot().create?.error).toBeTruthy();
    await store.submitCreate();
    await settle();
    const keys = ops(provider, ACTION_RUN)
      .map((call) => call.params as { action: string; args: { idempotency_key: string } })
      .filter((run) => run.action === CloudOps.machineCreate)
      .map((run) => run.args.idempotency_key);
    expect(keys).toEqual(["k1", "k1"]);
    expect(provider.machines.filter((machine) => machine.name === "retry-box").length).toBe(1);
  });

  test("an empty create name lets the owner name the machine; a snapshot source sends from_snapshot", async () => {
    const { provider, store } = await started();
    store.openCreate();
    await settle();
    const snapshot = store.getSnapshot().create!.snapshots![0];
    expect(ops(provider, CloudOps.snapshotList)[0].params).toEqual({});
    store.updateDraft({ from_snapshot: snapshot.id, memoryMb: 8192 });
    await store.submitCreate();
    expect(runs(provider).at(-1)).toEqual({
      action: CloudOps.machineCreate,
      args: { name: snapshot.name, size: { memory_mb: 8192 }, from_snapshot: snapshot.id, idempotency_key: "k1" },
    });
  });

  test("a declined create keeps the sheet open and drops the pending row", async () => {
    const { store } = await started(new MockCloudProvider({ confirm: false }));
    store.openCreate();
    await store.submitCreate();
    expect(store.getSnapshot().create?.submitting).toBe(false);
    expect(store.getSnapshot().pending).toEqual([]);
  });

  test("a pending intent shows until the owner's echo, then leaves the log", async () => {
    const provider = new MockCloudProvider({ holdEvents: true });
    const { store } = await started(provider);
    await store.pause(running().id);
    expect(store.getSnapshot().pending.map((intent) => intent.kind)).toEqual(["pause"]);
    expect(store.getSnapshot().rows.find((row) => row.id === running().id)?.pending).toBe("pause");
    provider.releaseEvents();
    await settle();
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().rows.find((row) => row.id === running().id)?.status).toBe("paused");
  });

  test("a rejected intent leaves the log and shows the error", async () => {
    const { provider, store } = await started();
    provider.failNext = CloudOps.machinePause;
    await store.pause(running().id);
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().error).toBeTruthy();
  });

  test("delete goes through the native confirmation action, never machine.delete", async () => {
    const { provider, store } = await started();
    const target = sampleMachines()[0];
    await store.requestDelete(target.id);
    await settle();
    expect(ops(provider, CloudOps.machineDelete)).toEqual([]);
    expect(runs(provider)).toEqual([
      { action: CloudOps.machineDelete, args: { machine: target.id, idempotency_key: "k1" } },
    ]);
    expect(store.getSnapshot().rows.map((row) => row.id)).not.toContain(target.id);
  });

  test("a declined delete confirmation keeps the machine and drops the intent", async () => {
    const { store } = await started(new MockCloudProvider({ confirm: false }));
    const target = sampleMachines()[0];
    await store.requestDelete(target.id);
    await settle();
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().rows.map((row) => row.id)).toContain(target.id);
  });

  test("a delete answered not_found drops the machine without an error", async () => {
    const provider = new MockCloudProvider();
    const { store } = await started(provider);
    provider.notFoundOnDelete = true;
    await store.requestDelete(running().id);
    await settle();
    expect(store.getSnapshot().error).toBeUndefined();
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().rows.map((row) => row.id)).not.toContain(running().id);
  });

  test("money and destructive ops never run from the page: the mock refuses them like the server", async () => {
    const provider = new MockCloudProvider();
    await expect(
      provider.call(CloudOps.machineCreate, { size: { memory_mb: 4096 }, idempotency_key: "x" }),
    ).rejects.toMatchObject({ code: "cmux.cloud.origin_refused" });
    const { store } = await started(provider);
    await store.select(running().id);
    await settle();
    const snapshot = store.getSnapshot().detail!.snapshots![0];
    await store.detail.createSnapshot(running().id);
    await store.restoreSnapshot(snapshot);
    await store.deleteSnapshot(snapshot.id);
    await store.resize(running().id, 8192);
    for (const op of [
      CloudOps.snapshotCreate,
      CloudOps.snapshotRestore,
      CloudOps.snapshotDelete,
      CloudOps.machineResize,
    ])
      expect(ops(provider, op)).toEqual([]);
    expect(runs(provider).map((run) => run.action)).toEqual([
      CloudOps.snapshotCreate,
      CloudOps.snapshotRestore,
      CloudOps.snapshotDelete,
      CloudOps.machineResize,
    ]);
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test("selecting a machine reads its detail once; a stale reply is dropped", async () => {
    const { provider, store } = await started();
    const [a, b] = sampleMachines();
    await Promise.all([store.select(a.id), store.select(b.id)]);
    await settle();
    expect(store.getSnapshot().detail?.machine).toBe(b.id);
    expect(ops(provider, CloudOps.snapshotList).map((call) => call.params)).toEqual([
      { machine: a.id },
      { machine: b.id },
    ]);
  });

  test("the transport going away shows the disconnected state and refuses changes", async () => {
    const { provider, store } = await started();
    provider.offline = true;
    await store.pause(sampleMachines()[0].id);
    expect(store.getSnapshot().connection).toBe("disconnected");
    const before = provider.calls.length;
    await store.resume(sampleMachines()[0].id);
    expect(provider.calls.length).toBe(before);
  });

  test("no client: disconnected, no calls", async () => {
    const store = new CloudStore(null);
    await store.start();
    expect(store.getSnapshot().connection).toBe("disconnected");
  });

  test("connect runs the native connect action", async () => {
    const { provider, store } = await started();
    await store.connect(sampleMachines()[0].id);
    expect(runs(provider).at(-1)).toEqual({
      action: CloudOps.machineConnect,
      args: { machine: sampleMachines()[0].id },
    });
  });
});

describe("CloudStore lifecycle and settlement", () => {
  test("subscribe, unsubscribe, subscribe (StrictMode) leaves one watch; the last unsubscribe closes it", async () => {
    const provider = new MockCloudProvider();
    const store = new CloudStore(provider, { newKey: () => "k" });
    store.subscribe(() => undefined)();
    const unsubscribe = store.subscribe(() => undefined);
    await settle();
    await settle();
    expect(provider.watchers).toBe(1);
    expect(store.getSnapshot().rows.length).toBe(sampleMachines().length);
    unsubscribe();
    expect(provider.watchers).toBe(0);
  });

  test("an event during the first list is merged by revision", async () => {
    const provider = new MockCloudProvider();
    provider.onList = () => provider.emitUpsert({ id: "vm_during", status: "running", name: "during", revision: "1" });
    const { store } = await started(provider);
    expect(store.getSnapshot().rows.map((row) => row.id)).toContain("vm_during");
  });

  test("two quick team switches leave one watch", async () => {
    const { provider, store } = await started();
    await Promise.all([store.selectTeam("team_acme"), store.selectTeam("team_personal")]);
    await settle();
    expect(provider.watchers).toBe(1);
  });

  test("an echo the owner normalized still settles the intent", async () => {
    const { provider, store } = await started();
    provider.renameTransform = (name) => name.toUpperCase();
    await store.rename(sampleMachines()[0].id, "renamed");
    await settle();
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().rows[0].title).toBe("RENAMED");
  });

  test("retry after a disconnect reconnects and refetches", async () => {
    const { provider, store } = await started();
    provider.offline = true;
    await store.pause(sampleMachines()[0].id);
    expect(store.getSnapshot().connection).toBe("disconnected");
    provider.offline = false;
    await store.retry();
    await settle();
    expect(store.getSnapshot().connection).toBe("connected");
    expect(provider.watchers).toBe(1);
  });

  test("every event of one projection change applies, even when they share its revision", async () => {
    const { provider, store } = await started();
    const [a, b] = sampleMachines();
    const revision = provider.revision + 1;
    provider.emitRaw({ type: "removed", revision, id: a.id });
    provider.emitRaw({ type: "removed", revision, id: b.id });
    await settle();
    const ids = store.getSnapshot().rows.map((row) => row.id);
    expect(ids).not.toContain(a.id);
    expect(ids).not.toContain(b.id);
    expect(store.getSnapshot().revision).toBe(revision);
  });

  test("an answer that arrives after a session restart still settles its intent", async () => {
    const { store } = await started();
    store.openCreate();
    store.updateDraft({ name: "restart-box" });
    const submitted = store.submitCreate();
    const resized = store.resize(running().id, 8192);
    store.stop();
    await Promise.all([submitted, resized]);
    await store.start();
    await settle();
    const { pending, create, rows } = store.getSnapshot();
    expect(pending).toEqual([]);
    expect(create).toBeUndefined();
    expect(rows.filter((row) => row.title === "restart-box").length).toBe(1);
  });

  test("the mock ledger refuses a key reused for other args, like the server", async () => {
    const provider = new MockCloudProvider();
    await provider.call(CloudOps.machinePause, { machine: "vm_a1", idempotency_key: "same" });
    await expect(
      provider.call(CloudOps.machinePause, { machine: "vm_b2", idempotency_key: "same" }),
    ).rejects.toMatchObject({ code: "cmux.cloud.idempotency_conflict" });
  });
});

describe("CloudStore on the cmux.wire/1 shapes", () => {
  test("machine ops send the server's snake_case params", async () => {
    const { provider, store } = await started();
    await store.rename(running().id, " renamed ");
    await store.setIdlePolicy(running().id, 300);
    await store.setIdlePolicy(running().id, null);
    expect(ops(provider, CloudOps.machineRename)[0].params).toEqual({
      machine: running().id,
      name: "renamed",
      idempotency_key: "k1",
    });
    expect(ops(provider, CloudOps.machineIdlePolicySet).map((call) => call.params)).toEqual([
      { machine: running().id, idle_seconds: 300, idempotency_key: "k2" },
      { machine: running().id, idle_seconds: 0, idempotency_key: "k3" },
    ]);
    expect(store.getSnapshot().machines.find((m) => m.id === running().id)?.idle_policy).toEqual({ idle_seconds: 0 });
    expect(store.getSnapshot().pending).toEqual([]);
  });

  test("a mutation result's revision settles the intent with no refetch", async () => {
    const provider = new MockCloudProvider({ holdEvents: true });
    const { store } = await started(provider);
    await store.pause(running().id);
    const [intent] = store.getSnapshot().pending;
    expect(intent.revision).toBe(provider.revision);
    expect(intent.revision).toBeGreaterThan(store.getSnapshot().revision);
    const lists = ops(provider, CloudOps.machineList).length;
    provider.releaseEvents();
    await settle();
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().revision).toBe(intent.revision!);
    expect(ops(provider, CloudOps.machineList).length).toBe(lists);
  });

  test("a resize sends size.memory_mb through the native action and the record shows the size", async () => {
    const { provider, store } = await started();
    await store.resize(running().id, 4096);
    expect(runs(provider).at(-1)).toEqual({
      action: CloudOps.machineResize,
      args: { machine: running().id, size: { memory_mb: 4096 }, idempotency_key: "k1" },
    });
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().machines.find((m) => m.id === running().id)?.size?.memory_mb).toBe(4096);
  });

  test("restore makes a new machine through the watch stream", async () => {
    const provider = new MockCloudProvider({ holdEvents: true });
    const { store } = await started(provider);
    await store.select(running().id);
    await settle();
    const snapshot = store.getSnapshot().detail!.snapshots![0];
    await store.restoreSnapshot(snapshot);
    expect(runs(provider).at(-1)).toEqual({
      action: CloudOps.snapshotRestore,
      args: { snapshot: snapshot.id, idempotency_key: "k1" },
    });
    expect(store.getSnapshot().rows.filter((row) => row.pending === "create").length).toBe(1);
    provider.releaseEvents();
    await settle();
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().rows.length).toBe(sampleMachines().length + 1);
  });

  test("the plan is read with the list and again after a confirmed change", async () => {
    const { provider, store } = await started();
    expect(store.getSnapshot().plan?.usage.active).toBe(3);
    const reads = ops(provider, CloudOps.planGet).length;
    await store.pause(running().id);
    await settle();
    expect(ops(provider, CloudOps.planGet).length).toBe(reads + 1);
    expect(store.getSnapshot().plan?.usage.active).toBe(2);
  });

  test("account ops no catalog declares show not available, never an error", async () => {
    const { store } = await started();
    expect(SERVER_GAPS).toEqual(expect.arrayContaining(Object.values(AccountOps)));
    expect(store.getSnapshot().unavailable).toContain(AccountOps.teamList);
    await store.selectTeam("team_acme");
    await settle();
    const { unavailable, error, rows } = store.getSnapshot();
    expect(unavailable).toContain(AccountOps.teamSelect);
    expect(error).toBeUndefined();
    expect(rows.length).toBe(sampleMachines().length);
  });

  test("a real error while reading the detail shows the banner", async () => {
    const provider = new MockCloudProvider();
    const { store } = await started(provider);
    provider.failNext = CloudOps.snapshotList;
    await store.select(running().id);
    await settle();
    expect(store.getSnapshot().error).toBeTruthy();
    expect(store.getSnapshot().unavailable).not.toContain(CloudOps.snapshotList);
  });

  test("the mock refuses a read with a key and a mutation without one, like the server", async () => {
    const provider = new MockCloudProvider();
    await expect(provider.call(CloudOps.machineList, { idempotency_key: "x" })).rejects.toMatchObject({
      code: "cmux.cloud.idempotency_key_forbidden",
    });
    await expect(provider.call(CloudOps.machinePause, { machine: "vm_a1" })).rejects.toMatchObject({
      code: "cmux.cloud.idempotency_key_required",
    });
    await expect(
      provider.call(CloudOps.machineRename, { machine: "vm_a1", displayName: "x", idempotency_key: "y" }),
    ).rejects.toMatchObject({
      code: "cmux.cloud.invalid_args",
    });
  });
});
