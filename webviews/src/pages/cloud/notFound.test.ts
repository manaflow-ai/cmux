// A 404 is two answers (R71 C11). With the kind's own not-found code (`vm_not_found`,
// `vm_snapshot_not_found`, `vm_firewall_rule_not_found`, `vm_file_not_found`,
// `vm_publication_not_found`) the route is there and the item is gone. A bare 404, or one with
// another code, means the Cloud API has no such route yet (production has no `/api/vm/:id/fs/*`,
// firewall, network or tunnel routes today): the page shows "Not available yet", never "gone".
import { describe, expect, test } from "bun:test";
import { pageError } from "../shared/pageClient";
import { MockCloudProvider, sampleMachines, type MockOptions } from "./mockProvider";
import { CloudOps, type CloudMachine } from "./ops";
import { CloudStore } from "./store";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const running = () => sampleMachines().find((machine) => machine.status === "running") as CloudMachine;

async function selected(options: MockOptions = {}) {
  const provider = new MockCloudProvider({ unsupported: [], ...options });
  let keys = 0;
  const store = new CloudStore(provider, { newKey: () => `k${++keys}` });
  store.subscribe(() => undefined);
  await store.start();
  await settle();
  await store.select(running().id);
  await settle();
  return { provider, store };
}

describe("Cloud route 404s", () => {
  test("a bare 404 on the files list shows not available and keeps no stale rows", async () => {
    const { provider, store } = await selected();
    await store.files.open("/home/cmux");
    expect(store.getSnapshot().detail!.files!.entries?.length).toBeGreaterThan(0);
    provider.routeMissing.add(CloudOps.fsList);
    await store.files.open("/home/cmux");
    const { detail, unavailable, error } = store.getSnapshot();
    expect(unavailable).toContain(CloudOps.fsList);
    expect(error).toBeUndefined();
    expect(detail!.files?.entries ?? []).toEqual([]);
  });

  test("bare 404s on the network sections show not available on selection, with no banner", async () => {
    const { store } = await selected({ routeMissing: [CloudOps.firewallList, CloudOps.networkList] });
    const { detail, unavailable, error } = store.getSnapshot();
    expect(unavailable).toEqual(expect.arrayContaining([CloudOps.firewallList, CloudOps.networkList]));
    expect(error).toBeUndefined();
    expect(detail!.firewall).toBeUndefined();
    expect(detail!.networks).toBeUndefined();
    // The served sections still read.
    expect(detail!.snapshots?.length).toBeGreaterThan(0);
  });

  test("a 404 with another kind's code is a missing route too", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    const store = new CloudStore(provider, { newKey: () => "k" });
    store.subscribe(() => undefined);
    await store.start();
    await settle();
    const call = provider.call.bind(provider);
    provider.call = async <R>(op: string, params: unknown): Promise<R> => {
      if (op === CloudOps.firewallList)
        throw pageError("cmux.cloud.not_found", "HTTP 404", false, { status: 404, upstream_code: "not_found" });
      return call<R>(op, params);
    };
    await store.select(running().id);
    expect(store.getSnapshot().unavailable).toContain(CloudOps.firewallList);
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test("a snapshot delete answered with the snapshot's own 404 settles the row as gone", async () => {
    const { provider, store } = await selected();
    const snapshot = store.getSnapshot().detail!.snapshots![0];
    provider.goneNext = CloudOps.snapshotDelete;
    await store.deleteSnapshot(running().id, snapshot.id);
    const { detail, unavailable, error } = store.getSnapshot();
    expect(error).toBeUndefined();
    expect(unavailable).not.toContain(CloudOps.snapshotDelete);
    expect(detail!.snapshots!.map((s) => s.id)).not.toContain(snapshot.id);
  });

  test("a bare 404 on a snapshot delete shows not available and keeps the row", async () => {
    const { provider, store } = await selected();
    const snapshot = store.getSnapshot().detail!.snapshots![0];
    provider.routeMissing.add(CloudOps.snapshotDelete);
    await store.deleteSnapshot(running().id, snapshot.id);
    const { detail, unavailable, error } = store.getSnapshot();
    expect(unavailable).toContain(CloudOps.snapshotDelete);
    expect(error).toBeUndefined();
    expect(detail!.snapshots!.map((s) => s.id)).toContain(snapshot.id);
  });

  test("a machine delete answered vm_not_found drops the machine without an error (unchanged)", async () => {
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

  test("a bare 404 on a machine delete shows not available and keeps the machine", async () => {
    const { provider, store } = await selected();
    provider.routeMissing.add(CloudOps.machineDelete);
    await store.requestDelete(running().id);
    await settle();
    const { rows, pending, unavailable } = store.getSnapshot();
    expect(unavailable).toContain(CloudOps.machineDelete);
    expect(pending).toEqual([]);
    expect(rows.map((row) => row.id)).toContain(running().id);
  });

  test("a file remove answered vm_file_not_found refreshes the folder without an error", async () => {
    const { provider, store } = await selected();
    await store.files.open("/home/cmux");
    provider.goneNext = CloudOps.fsRemove;
    await store.files.remove("/home/cmux/notes.txt");
    const { detail, unavailable, error } = store.getSnapshot();
    expect(error).toBeUndefined();
    expect(unavailable).not.toContain(CloudOps.fsRemove);
    expect(detail!.files!.entries?.map((entry) => entry.name)).not.toContain("notes.txt");
  });
});
