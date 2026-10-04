// File push and pull after C10: the native action answers `{transfer, state: running}` at once, and
// the copy's end comes as the `cmux.cloud.file.transfer.changed` event. The page subscribes before
// it starts a transfer (no polling) and shows `transfer_busy` as a retryable message.
import { describe, expect, test } from "bun:test";
import { MockCloudProvider, sampleMachines, type MockOptions } from "./mockProvider";
import { ACTION_RUN, CloudOps, type CloudMachine } from "./ops";
import { CloudStore } from "./store";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const running = () => sampleMachines().find((machine) => machine.status === "running") as CloudMachine;

async function browsing(options: MockOptions = {}) {
  const provider = new MockCloudProvider({ holdTransfers: true, ...options });
  let keys = 0;
  const store = new CloudStore(provider, { newKey: () => `k${++keys}` });
  store.subscribe(() => undefined);
  await store.start();
  await settle();
  await store.select(running().id);
  await settle();
  await store.files.open("/home/cmux");
  return { provider, store };
}

const transfers = (store: CloudStore) => store.getSnapshot().transfers ?? [];
const names = (store: CloudStore) => store.getSnapshot().detail!.files!.entries?.map((entry) => entry.name);

describe("Cloud file transfers", () => {
  test("a push shows running, then done after the transfer event, and the folder shows the file", async () => {
    const { provider, store } = await browsing();
    await store.files.push();
    // The page listens before the action runs, so an early end cannot be missed.
    const order = provider.calls.map((call) => call.op);
    expect(order.indexOf(`subscribe ${CloudOps.fileTransferChanged}`)).toBeGreaterThanOrEqual(0);
    expect(order.indexOf(`subscribe ${CloudOps.fileTransferChanged}`)).toBeLessThan(order.lastIndexOf(ACTION_RUN));
    expect(transfers(store)).toEqual([
      expect.objectContaining({ machine: running().id, direction: "push", state: "running" }),
    ]);
    expect(names(store)).not.toContain("upload.txt");
    provider.finishTransfers();
    await settle();
    expect(transfers(store)).toEqual([expect.objectContaining({ direction: "push", state: "done", bytes: 9 })]);
    expect(names(store)).toContain("upload.txt");
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test("a pull shows running until its event, and the event names the transfer", async () => {
    const { provider, store } = await browsing();
    await store.files.pull("/home/cmux/notes.txt");
    const [started] = transfers(store);
    expect(started).toMatchObject({ direction: "pull", path: "/home/cmux/notes.txt", state: "running" });
    const [ended] = provider.finishTransfers();
    expect(ended.transfer).toBe(started.transfer);
    expect(transfers(store)).toEqual([expect.objectContaining({ transfer: started.transfer, state: "done" })]);
  });

  test("an event that comes before the action's answer still settles the transfer", async () => {
    const { store } = await browsing({ holdTransfers: false });
    await store.files.push();
    await settle();
    expect(transfers(store)).toEqual([expect.objectContaining({ direction: "push", state: "done" })]);
  });

  test("transfer_busy shows a retryable message, no error banner, and Retry runs the action again", async () => {
    const { provider, store } = await browsing();
    for (let i = 0; i < 4; i += 1) await store.files.pull("/home/cmux/notes.txt");
    await store.files.push();
    expect(store.getSnapshot().error).toBeUndefined();
    expect(store.getSnapshot().detail!.files!.busy).toEqual({ direction: "push", path: "/home/cmux" });
    expect(transfers(store).filter((t) => t.direction === "push")).toEqual([]);
    provider.finishTransfers();
    await store.files.retryTransfer();
    expect(store.getSnapshot().detail!.files!.busy).toBeUndefined();
    expect(transfers(store).filter((t) => t.direction === "push")).toEqual([
      expect.objectContaining({ state: "running" }),
    ]);
  });

  test("a declined panel starts no transfer", async () => {
    const { store } = await browsing({ confirm: false });
    await store.files.push();
    expect(transfers(store)).toEqual([]);
  });
});
