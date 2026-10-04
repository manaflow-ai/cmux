import { describe, expect, test } from "bun:test";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { ACTION_RUN, CloudOps, type CloudMachine } from "./ops";
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

describe("CloudStore", () => {
  test("signed in: reads auth, watches machines and lists them once", async () => {
    const { provider, store } = await started();
    const snap = store.getSnapshot();
    expect(snap.connection).toBe("connected");
    expect(snap.auth?.signed_in).toBe(true);
    expect(snap.rows.map((row) => row.id)).toEqual(sampleMachines().map((machine) => machine.id));
    expect(ops(provider, CloudOps.machineList).length).toBe(1);
    expect(provider.watchers).toBe(1);
  });

  test("signed out: no machine op runs and no watch starts", async () => {
    const provider = new MockCloudProvider({ signedIn: false });
    const { store } = await started(provider);
    expect(store.getSnapshot().auth?.signed_in).toBe(false);
    expect(machineOps(provider)).toEqual([]);
    expect(provider.watchers).toBe(0);
  });

  test("sign in re-reads auth and then loads machines", async () => {
    const provider = new MockCloudProvider({ signedIn: false });
    const { store } = await started(provider);
    await store.signIn();
    await settle();
    expect(ops(provider, CloudOps.authSignIn)).toEqual([]);
    expect(ops(provider, ACTION_RUN).map((call) => (call.params as { action: string }).action)).toEqual([
      CloudOps.authSignIn,
    ]);
    expect(store.getSnapshot().auth?.signed_in).toBe(true);
    expect(store.getSnapshot().rows.length).toBe(sampleMachines().length);
  });

  test("a watch event updates the list without a refetch", async () => {
    const { provider, store } = await started();
    const lists = ops(provider, CloudOps.machineList).length;
    const target = sampleMachines()[0];
    provider.emitUpsert({ ...target, status: "paused" });
    await settle();
    expect(store.getSnapshot().rows.find((row) => row.id === target.id)?.status).toBe("paused");
    provider.emitUpsert({ id: "vm-new", provider: "freestyle", status: "provisioning", display_name: "new-box" });
    await settle();
    expect(store.getSnapshot().rows.map((row) => row.id)).toContain("vm-new");
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

  test("create sends exactly one idempotency key on a double submit", async () => {
    const { provider, store } = await started();
    store.openCreate();
    store.updateDraft({ name: "build-box" });
    const first = store.submitCreate();
    const second = store.submitCreate();
    await Promise.all([first, second]);
    await settle();
    const creates = ops(provider, CloudOps.machineCreate);
    expect(creates.length).toBe(1);
    const key = (creates[0].params as { idempotency_key: string }).idempotency_key;
    expect(typeof key).toBe("string");
    expect(key.length).toBeGreaterThan(0);
    expect(store.getSnapshot().create).toBeUndefined();
    expect(store.getSnapshot().rows.some((row) => row.title === "build-box")).toBe(true);
  });

  test("a create retried after a transport failure reuses the same key", async () => {
    const { provider, store } = await started();
    store.openCreate();
    store.updateDraft({ name: "retry-box" });
    provider.failNext = CloudOps.machineCreate;
    await store.submitCreate();
    expect(store.getSnapshot().create?.error).toBeTruthy();
    await store.submitCreate();
    await settle();
    const keys = ops(provider, CloudOps.machineCreate).map(
      (call) => (call.params as { idempotency_key: string }).idempotency_key,
    );
    expect(keys.length).toBe(2);
    expect(keys[0]).toBe(keys[1]);
    expect(provider.machines.filter((machine) => machine.display_name === "retry-box").length).toBe(1);
  });

  test("a pending intent shows until the owner's echo, then leaves the log", async () => {
    const provider = new MockCloudProvider({ holdEvents: true });
    const { store } = await started(provider);
    const running = sampleMachines().find((machine) => machine.status === "running") as CloudMachine;
    await store.pause(running.id);
    expect(store.getSnapshot().pending.map((intent) => intent.kind)).toEqual(["pause"]);
    expect(store.getSnapshot().rows.find((row) => row.id === running.id)?.pending).toBe("pause");
    provider.releaseEvents();
    await settle();
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().rows.find((row) => row.id === running.id)?.status).toBe("paused");
  });

  test("a rejected intent leaves the log and shows the error", async () => {
    const { provider, store } = await started();
    const running = sampleMachines().find((machine) => machine.status === "running") as CloudMachine;
    provider.failNext = CloudOps.machinePause;
    await store.pause(running.id);
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().error).toBeTruthy();
  });

  test("delete goes through the native confirmation action, never machine.delete", async () => {
    const { provider, store } = await started();
    const target = sampleMachines()[0];
    await store.requestDelete(target.id);
    await settle();
    expect(ops(provider, CloudOps.machineDelete)).toEqual([]);
    const runs = ops(provider, ACTION_RUN);
    expect(runs.length).toBe(1);
    expect(runs[0].params).toMatchObject({ action: CloudOps.machineDelete, args: { machine: target.id } });
    expect(store.getSnapshot().rows.map((row) => row.id)).not.toContain(target.id);
  });

  test("a declined delete confirmation keeps the machine and drops the intent", async () => {
    const provider = new MockCloudProvider({ confirm: false });
    const { store } = await started(provider);
    const target = sampleMachines()[0];
    await store.requestDelete(target.id);
    await settle();
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().rows.map((row) => row.id)).toContain(target.id);
  });

  test("snapshot delete, firewall delete and billing go through native actions", async () => {
    const { provider, store } = await started();
    const target = sampleMachines()[0];
    await store.select(target.id);
    await settle();
    const detail = store.getSnapshot().detail;
    expect(detail?.snapshots?.length).toBeGreaterThan(0);
    expect(detail?.firewall?.length).toBeGreaterThan(0);
    await store.deleteSnapshot(target.id, detail!.snapshots![0].id);
    await store.deleteFirewallRule(target.id, detail!.firewall![0].id);
    await store.openBilling();
    expect(ops(provider, CloudOps.snapshotDelete)).toEqual([]);
    expect(ops(provider, CloudOps.firewallDelete)).toEqual([]);
    expect(ops(provider, CloudOps.billingOpen)).toEqual([]);
    expect(ops(provider, ACTION_RUN).map((call) => (call.params as { action: string }).action)).toEqual([
      CloudOps.snapshotDelete,
      CloudOps.firewallDelete,
      CloudOps.billingOpen,
    ]);
  });

  test("selecting a machine reads its detail once; a stale reply is dropped", async () => {
    const { provider, store } = await started();
    const [a, b] = sampleMachines();
    const first = store.select(a.id);
    const second = store.select(b.id);
    await Promise.all([first, second]);
    await settle();
    expect(store.getSnapshot().detail?.machine).toBe(b.id);
    expect(ops(provider, CloudOps.machineStats).length).toBe(2);
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
    expect(ops(provider, ACTION_RUN).at(-1)?.params).toEqual({
      action: CloudOps.machineConnect,
      args: { machine: sampleMachines()[0].id },
    });
  });
});

describe("CloudStore lifecycle and settlement (review fixes)", () => {
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
    provider.onList = () =>
      provider.emitUpsert({ id: "vm-during", provider: "freestyle", status: "running", display_name: "during" });
    const { store } = await started(provider);
    expect(store.getSnapshot().rows.map((row) => row.id)).toContain("vm-during");
  });

  test("two quick team switches leave one watch and the last team's list", async () => {
    const { provider, store } = await started();
    await Promise.all([store.selectTeam("team-acme"), store.selectTeam("team-personal")]);
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

  test("an answered intent settles on the machine's next event, whatever its value", async () => {
    const provider = new MockCloudProvider({ holdEvents: true });
    const { store } = await started(provider);
    provider.renameTransform = (name) => `${name}-x`;
    await store.rename(sampleMachines()[0].id, "held");
    expect(store.getSnapshot().pending.map((intent) => intent.kind)).toEqual(["rename"]);
    provider.releaseEvents();
    await settle();
    expect(store.getSnapshot().pending).toEqual([]);
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

  test("an unknown status from the owner shows as unknown", async () => {
    const { provider, store } = await started();
    provider.emitUpsert({ ...sampleMachines()[0], status: "hibernating" as never });
    await settle();
    expect(store.getSnapshot().rows[0].status).toBe("unknown");
  });
});
