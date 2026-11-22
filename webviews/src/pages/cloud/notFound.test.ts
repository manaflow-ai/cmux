// `cmux.cloud.not_found` on a delete or remove means the item is gone (`cloud.machine.not_found`,
// `cloud.snapshot.not_found`, a daemon `fs.not_found`): the outcome the person asked for, so no error
// shows. Elsewhere it is an error like any other. A file op on a machine whose daemon has no `fs-v1`
// answers `cmux.cloud.unsupported`: "Not available yet" for that machine's files only.
import { describe, expect, test } from "bun:test";
import { pageError } from "../shared/pageClient";
import { MockCloudProvider, sampleMachines, type MockOptions } from "./mockProvider";
import { ACTION_RUN, CloudOps } from "./ops";
import { CloudStore } from "./store";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const running = () => sampleMachines().find((machine) => machine.status === "running" && !machine.classic)!;

async function selected(options: MockOptions = {}, machine = running().id) {
  const provider = new MockCloudProvider({ unsupported: [], ...options });
  let keys = 0;
  const store = new CloudStore(provider, { newKey: () => `k${++keys}` });
  store.subscribe(() => undefined);
  await store.start();
  await settle();
  await store.select(machine);
  await settle();
  return { provider, store };
}

describe("Cloud not_found and unsupported answers", () => {
  test("a snapshot delete answered not_found settles the row as gone", async () => {
    const { provider, store } = await selected();
    const snapshot = store.getSnapshot().detail!.snapshots![0];
    provider.goneNext = CloudOps.snapshotDelete;
    await store.deleteSnapshot(snapshot.id);
    const { detail, unavailable, error } = store.getSnapshot();
    expect(error).toBeUndefined();
    expect(unavailable).not.toContain(CloudOps.snapshotDelete);
    expect(detail!.snapshots!.map((s) => s.id)).not.toContain(snapshot.id);
  });

  test("a machine delete answered not_found drops the machine without an error", async () => {
    const { provider, store } = await selected();
    provider.notFoundOnDelete = true;
    await store.requestDelete(running().id);
    await settle();
    const { rows, pending, unavailable, error } = store.getSnapshot();
    expect(error).toBeUndefined();
    expect(pending).toEqual([]);
    expect(unavailable).not.toContain(CloudOps.machineDelete);
    expect(rows.map((row) => row.id)).not.toContain(running().id);
  });

  test("a machine delete not_found from the host, with no details, is gone too", async () => {
    const { provider, store } = await selected();
    const call = provider.call.bind(provider);
    provider.call = async <R>(op: string, params: unknown): Promise<R> => {
      if (op === ACTION_RUN) throw pageError("cmux.cloud.not_found", "gone");
      return call<R>(op, params);
    };
    await store.requestDelete(running().id);
    const { pending, error } = store.getSnapshot();
    expect(error).toBeUndefined();
    expect(pending).toEqual([]);
  });

  test("a file remove answered not_found refreshes the folder without an error", async () => {
    const { provider, store } = await selected();
    await store.files.open("/home/cmux");
    provider.goneNext = CloudOps.fsRemove;
    await store.files.remove("/home/cmux/notes.txt");
    const { detail, unavailable, error } = store.getSnapshot();
    expect(error).toBeUndefined();
    expect(unavailable).not.toContain(CloudOps.fsRemove);
    expect(detail!.files!.entries?.map((entry) => entry.name)).not.toContain("notes.txt");
  });

  test("not_found on a read is an error, not a missing feature", async () => {
    const { provider, store } = await selected();
    await store.files.open("/home/cmux");
    await store.files.open("/home/cmux/nope");
    expect(store.getSnapshot().error).toBe("/home/cmux/nope does not exist");
    expect(store.getSnapshot().unavailable).toEqual([]);
    expect(provider.calls.filter((call) => call.op === CloudOps.fsList).length).toBe(2);
  });

  test("a daemon without fs-v1: the files of that machine only are not available", async () => {
    const { provider, store } = await selected();
    provider.fsMachines.delete(running().id);
    await store.files.open("/home/cmux");
    const files = store.getSnapshot().detail!.files!;
    expect(files.unavailable).toBe(true);
    expect(files.entries).toEqual([]);
    expect(store.getSnapshot().unavailable).not.toContain(CloudOps.fsList);
    expect(store.getSnapshot().error).toBeUndefined();
    // Another machine whose daemon has file ops lists its folder.
    const other = sampleMachines().find((machine) => machine.status === "paused")!;
    provider.emitUpsert({ ...other, status: "running" });
    await settle();
    await store.select(other.id);
    await store.files.open("/home/cmux");
    expect(store.getSnapshot().detail!.files!.unavailable).toBeUndefined();
    expect(store.getSnapshot().detail!.files!.entries?.length).toBeGreaterThan(0);
  });

  test("the mock answers the server's file gate codes", async () => {
    const provider = new MockCloudProvider();
    const list = (machine: string) => provider.call(CloudOps.fsList, { machine, path: "/home/cmux" });
    provider.fsMachines.delete("vm_a1");
    await expect(list("vm_a1")).rejects.toMatchObject({
      code: "cmux.cloud.unsupported",
      message: "The machine's cmux daemon has no file ops yet (needs fs-v1)",
    });
    provider.fsMachines.add("vm_a1");
    // Not bound to the overlay yet (provisioning, or classic before its upgrade).
    await expect(list("vm_c3")).rejects.toMatchObject({ code: "cmux.cloud.not_bound" });
    await expect(list("vm_d4")).rejects.toMatchObject({ code: "cmux.cloud.not_bound" });
    await expect(list("vm_b2")).rejects.toMatchObject({ code: "cmux.cloud.machine_paused" });
    provider.fs.opsBusy = true;
    await expect(list("vm_a1")).rejects.toMatchObject({ code: "cmux.cloud.file_ops_busy", retryable: true });
  });
});
