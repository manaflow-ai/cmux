// A create at the running-machines limit: the platform pauses an idle machine and the page shows it
// paused; with nothing idle the sheet offers to pause the running machine used longest ago, then creates.
import { expect, test } from "bun:test";
import { MockCloudProvider } from "./mockProvider";
import { ACTION_RUN, CloudOps } from "./ops";
import { CloudStore } from "./store";

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function atLimit(idle: string[] = []) {
  const provider = new MockCloudProvider({ unsupported: [] });
  provider.account.plan.max_active = provider.plan.usage.active;
  provider.idle = idle;
  let key = 0;
  const store = new CloudStore(provider, { newKey: () => `key_${++key}` });
  const unsubscribe = store.subscribe(() => undefined);
  for (let i = 0; i < 4; i++) await flush();
  store.openCreate();
  await flush();
  store.updateDraft({ memoryMb: 4096 });
  await store.submitCreate();
  for (let i = 0; i < 4; i++) await flush();
  return { store, provider, unsubscribe };
}

const status = (store: CloudStore, id: string) => store.getSnapshot().machines.find((m) => m.id === id)?.status;
const creates = (p: MockCloudProvider) =>
  p.calls
    .filter((c) => c.op === ACTION_RUN && (c.params as { action?: string }).action === CloudOps.machineCreate)
    .map((c) => (c.params as { args: { idempotency_key: string } }).args.idempotency_key);

test("an idle machine: the create goes through and the idle one shows paused", async () => {
  const { store, provider, unsubscribe } = await atLimit(["vm_a1"]);
  expect(creates(provider)).toHaveLength(1);
  expect(store.getSnapshot().create).toBeUndefined();
  expect(status(store, "vm_a1")).toBe("paused");
  expect(store.getSnapshot().machines.some((m) => m.id.startsWith("vm_new"))).toBe(true);
  unsubscribe();
});

test("the create's answer alone shows the paused machine, and an older answer does not undo an event", async () => {
  const { store, provider, unsubscribe } = await atLimit();
  store.closeCreate();
  const a1 = provider.machines.find((m) => m.id === "vm_a1")!;
  const answer = { ...a1, status: "paused" as const, revision: String(Number(a1.revision) + 1) };
  const madeRoom = (store as unknown as { madeRoom(machine: unknown): void }).madeRoom.bind(store);
  madeRoom(answer);
  expect(status(store, "vm_a1")).toBe("paused");
  provider.emitUpsert({ ...a1, status: "running", revision: String(Number(a1.revision) + 2) });
  await flush();
  madeRoom(answer);
  expect(status(store, "vm_a1")).toBe("running");
  unsubscribe();
});

test("nothing idle: the sheet offers to pause the running machine used longest ago, then creates", async () => {
  const { store, provider, unsubscribe } = await atLimit();
  expect(store.getSnapshot().create?.offer).toEqual({ kind: "pause", machine: "vm_d4", name: "old-box" });
  expect(store.getSnapshot().create?.refusal?.kind).toBe("quota_exceeded");
  expect(store.getSnapshot().error).toBeUndefined();
  await store.makeRoom();
  for (let i = 0; i < 4; i++) await flush();
  expect(provider.calls.filter((c) => c.op === CloudOps.machinePause)).toHaveLength(1);
  // The refused key replays its refusal: the create after the pause sends a new one.
  expect(new Set(creates(provider)).size).toBe(2);
  expect(status(store, "vm_d4")).toBe("paused");
  expect(store.getSnapshot().create).toBeUndefined();
  unsubscribe();
});

test("a refusal without an offer still gets a new key, so room made by hand lets Create through", async () => {
  const provider = new MockCloudProvider({ unsupported: [] });
  provider.account.plan.max_active = provider.plan.usage.active;
  // A teammate's machines hold the slots: the platform names none of the person's.
  for (const machine of provider.machines)
    if (machine.status === "running") Object.assign(machine, { status: "starting" });
  let key = 0;
  const store = new CloudStore(provider, { newKey: () => `key_${++key}` });
  const unsubscribe = store.subscribe(() => undefined);
  for (let i = 0; i < 4; i++) await flush();
  store.openCreate();
  await flush();
  store.updateDraft({ memoryMb: 4096 });
  await store.submitCreate();
  for (let i = 0; i < 4; i++) await flush();
  expect(store.getSnapshot().create?.offer).toBeUndefined();
  expect(store.getSnapshot().create?.refusal?.kind).toBe("quota_exceeded");
  provider.account.plan.max_active += 1;
  await store.submitCreate();
  for (let i = 0; i < 4; i++) await flush();
  expect(new Set(creates(provider)).size).toBe(2);
  expect(store.getSnapshot().create).toBeUndefined();
  unsubscribe();
});
