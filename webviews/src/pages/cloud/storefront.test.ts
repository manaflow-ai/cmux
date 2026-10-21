import { describe, expect, test } from "bun:test";
import { MockCloudProvider } from "./mockProvider";
import { ACTION_RUN, CloudOps } from "./ops";
import { CloudStore, parseView } from "./store";
import { tierHint } from "./Storefront";
import { L } from "./strings";

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function started(provider = new MockCloudProvider()) {
  let key = 0;
  const store = new CloudStore(provider, { newKey: () => `key_${++key}` });
  const unsubscribe = store.subscribe(() => undefined);
  await flush();
  await flush();
  return { store, provider, unsubscribe };
}

const connects = (provider: MockCloudProvider) =>
  provider.calls.filter(
    (call) => call.op === ACTION_RUN && (call.params as { action?: string }).action === CloudOps.machineConnect,
  );

describe("Cloud storefront", () => {
  test("#/get opens the storefront; anything else the machine list", () => {
    expect(parseView("#/get")).toBe("get");
    expect(parseView("#get?x=1")).toBe("get");
    expect(parseView("")).toBe("machines");
    expect(parseView("#/machines")).toBe("machines");
  });

  test("Get on a size opens the create sheet on that size", async () => {
    const { store, unsubscribe } = await started();
    store.openCreate(8192, true);
    expect(store.getSnapshot().create?.memoryMb).toBe(8192);
    expect(store.getSnapshot().create?.openWhenRunning).toBe(true);
    unsubscribe();
  });

  test("a size the plan locks falls back to the plan's first allowed size", async () => {
    const { store, unsubscribe } = await started();
    store.openCreate(32_768, true);
    expect(store.getSnapshot().create?.memoryMb).toBe(4096);
    unsubscribe();
  });

  test("a machine created from Get opens in a workspace once it runs, once", async () => {
    const { store, provider, unsubscribe } = await started();
    store.openCreate(8192, true);
    await store.submitCreate();
    await flush();
    const id = store.getSnapshot().openWhenRunning;
    expect(id).toBeDefined();
    expect(store.getSnapshot().view).toBe("machines");
    expect(store.getSnapshot().selection).toBe(id);
    expect(connects(provider)).toHaveLength(0);
    const machine = provider.machines.find((m) => m.id === id)!;
    provider.emitUpsert({ ...machine, status: "running", revision: "2" });
    await flush();
    expect(connects(provider)).toHaveLength(1);
    expect((connects(provider)[0]!.params as { args: { machine: string } }).args.machine).toBe(id!);
    expect(store.getSnapshot().openWhenRunning).toBeUndefined();
    provider.emitUpsert({ ...machine, status: "running", revision: "3" });
    await flush();
    expect(connects(provider)).toHaveLength(1);
    unsubscribe();
  });

  test("New Machine does not open the machine it creates", async () => {
    const { store, provider, unsubscribe } = await started();
    store.openCreate();
    await store.submitCreate();
    await flush();
    expect(store.getSnapshot().openWhenRunning).toBeUndefined();
    const created = provider.machines.at(-1)!;
    provider.emitUpsert({ ...created, status: "running", revision: "2" });
    await flush();
    expect(connects(provider)).toHaveLength(0);
    unsubscribe();
  });

  test("a machine that fails while provisioning drops the wish without connecting", async () => {
    const { store, provider, unsubscribe } = await started();
    store.openCreate(4096, true);
    await store.submitCreate();
    await flush();
    const id = store.getSnapshot().openWhenRunning!;
    const machine = provider.machines.find((m) => m.id === id)!;
    provider.emitUpsert({ ...machine, status: "failed", revision: "2" });
    await flush();
    expect(store.getSnapshot().openWhenRunning).toBeUndefined();
    expect(connects(provider)).toHaveLength(0);
    unsubscribe();
  });

  test("a failed plan read shows as failed, and Retry reads it again", async () => {
    const provider = new MockCloudProvider();
    provider.failNext = CloudOps.planGet;
    const { store, unsubscribe } = await started(provider);
    await flush();
    expect(store.getSnapshot().plan).toBeUndefined();
    expect(store.getSnapshot().planFailed).toBe(true);
    await store.retryPlan();
    expect(store.getSnapshot().plan).toBeDefined();
    expect(store.getSnapshot().planFailed).toBe(false);
    unsubscribe();
  });

  test("a create answered after a team switch does not open or select the old team's machine", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    const { store, unsubscribe } = await started(provider);
    store.openCreate(4096, true);
    const created = store.submitCreate();
    void store.selectTeam("team_acme");
    await created;
    await flush();
    expect(store.getSnapshot().openWhenRunning).toBeUndefined();
    unsubscribe();
  });

  test("size hints grow with memory", () => {
    expect(tierHint(4096)).toBe(L.storeTierSmall);
    expect(tierHint(8192)).toBe(L.storeTierMedium);
    expect(tierHint(16_384)).toBe(L.storeTierLarge);
    expect(tierHint(65_536)).toBe(L.storeTierHuge);
  });
});
