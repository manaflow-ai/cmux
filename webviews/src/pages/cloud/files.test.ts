// The Files section of a machine: daemon `fs.*` ops on the link behind `fs-v1` (contract 2.4). List,
// stat and read for a preview of small text files, mkdir and write as ops, and remove, push and pull
// only as native actions.
import { describe, expect, test } from "bun:test";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { ACTION_RUN, CloudOps, type CloudMachine } from "./ops";
import { CloudStore } from "./store";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const running = () =>
  sampleMachines().find((machine) => machine.status === "running" && !machine.classic) as CloudMachine;

async function browsing(provider = new MockCloudProvider()) {
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

const ops = (provider: MockCloudProvider, op: string) => provider.calls.filter((call) => call.op === op);
const files = (store: CloudStore) => store.getSnapshot().detail!.files!;
const runs = (provider: MockCloudProvider) =>
  ops(provider, ACTION_RUN).map((call) => call.params as { action: string; args: Record<string, unknown> });

describe("Cloud files", () => {
  test("a folder lists with fs.list {machine, path}", async () => {
    const { provider, store } = await browsing();
    expect(ops(provider, CloudOps.fsList)[0].params).toEqual({ machine: running().id, path: "/home/cmux" });
    expect(files(store).path).toBe("/home/cmux");
    expect(files(store).entries?.map((entry) => entry.name)).toEqual(["notes.txt", "src", "big.bin", "latest"]);
  });

  test("a small text file previews through stat then read", async () => {
    const { provider, store } = await browsing();
    await store.files.preview("/home/cmux/notes.txt");
    expect(ops(provider, CloudOps.fsStat)[0].params).toEqual({ machine: running().id, path: "/home/cmux/notes.txt" });
    expect(ops(provider, CloudOps.fsRead)[0].params).toEqual({ machine: running().id, path: "/home/cmux/notes.txt" });
    expect(files(store).preview).toMatchObject({ path: "/home/cmux/notes.txt", text: "hello cloud\n" });
  });

  test("a large file is not read for a preview", async () => {
    const { provider, store } = await browsing();
    await store.files.preview("/home/cmux/big.bin");
    expect(ops(provider, CloudOps.fsRead)).toEqual([]);
    expect(files(store).preview).toMatchObject({ path: "/home/cmux/big.bin", tooLarge: true });
  });

  test("a folder opens and Up goes back to its parent", async () => {
    const { store } = await browsing();
    await store.files.open("/home/cmux/src");
    expect(files(store).entries?.map((entry) => entry.name)).toEqual(["main.rs"]);
    await store.files.up();
    expect(files(store).path).toBe("/home/cmux");
  });

  test("mkdir and write are ops with an idempotency key", async () => {
    const { provider, store } = await browsing();
    await store.files.mkdir("logs");
    expect(ops(provider, CloudOps.fsMkdir)[0].params).toEqual({
      machine: running().id,
      path: "/home/cmux/logs",
      idempotency_key: "k1",
    });
    expect(files(store).entries?.map((entry) => entry.name)).toContain("logs");
    await store.files.save("/home/cmux/notes.txt", "changed\n");
    expect(ops(provider, CloudOps.fsWrite)[0].params).toEqual({
      machine: running().id,
      path: "/home/cmux/notes.txt",
      dataBase64: btoa("changed\n"),
      idempotency_key: "k2",
    });
    await store.files.preview("/home/cmux/notes.txt");
    expect(files(store).preview?.text).toBe("changed\n");
  });

  test("a folder name with a slash or a dot segment is refused before any call", async () => {
    const { provider, store } = await browsing();
    await store.files.mkdir("a/b");
    await store.files.mkdir("..");
    expect(ops(provider, CloudOps.fsMkdir)).toEqual([]);
  });

  test("remove, push and pull run only as native actions", async () => {
    const { provider, store } = await browsing();
    await store.files.remove("/home/cmux/notes.txt");
    await store.files.push();
    await store.files.pull("/home/cmux/src/main.rs");
    for (const op of [CloudOps.fsRemove, CloudOps.filePush, CloudOps.filePull]) expect(ops(provider, op)).toEqual([]);
    expect(runs(provider)).toEqual([
      {
        action: CloudOps.fsRemove,
        args: { machine: running().id, path: "/home/cmux/notes.txt", idempotency_key: "k1" },
      },
      { action: CloudOps.filePush, args: { machine: running().id, path: "/home/cmux", idempotency_key: "k2" } },
      {
        action: CloudOps.filePull,
        args: { machine: running().id, path: "/home/cmux/src/main.rs", idempotency_key: "k3" },
      },
    ]);
    expect(files(store).entries?.map((entry) => entry.name)).not.toContain("notes.txt");
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test("a declined remove keeps the file", async () => {
    const { store } = await browsing(new MockCloudProvider({ confirm: false }));
    await store.files.remove("/home/cmux/notes.txt");
    expect(files(store).entries?.map((entry) => entry.name)).toContain("notes.txt");
  });

  test("a reply for another machine is dropped", async () => {
    const { store } = await browsing();
    const [, other] = sampleMachines();
    const listing = store.files.open("/home/cmux/src");
    await store.select(other.id);
    await listing;
    expect(store.getSnapshot().detail?.machine).toBe(other.id);
    expect(store.getSnapshot().detail?.files).toBeUndefined();
  });

  test("an item without a size is never read for a preview", async () => {
    const { provider, store } = await browsing();
    await store.files.preview("/home/cmux/latest");
    expect(ops(provider, CloudOps.fsRead)).toEqual([]);
    expect(files(store).preview).toMatchObject({ path: "/home/cmux/latest", unread: true });
  });

  test("Browse during the first detail read keeps the listing", async () => {
    const provider = new MockCloudProvider();
    const store = new CloudStore(provider, { newKey: () => "k" });
    store.subscribe(() => undefined);
    await store.start();
    await settle();
    const selection = store.select(running().id);
    const listing = store.files.open("/home/cmux");
    await Promise.all([selection, listing]);
    expect(files(store).entries?.map((entry) => entry.name)).toContain("notes.txt");
    expect(store.getSnapshot().detail!.snapshots?.length).toBeGreaterThan(0);
  });

  test("a save after a preview replaces only the revision it read (baseRevision)", async () => {
    const { provider, store } = await browsing();
    await store.files.preview("/home/cmux/notes.txt");
    const revision = files(store).preview?.revision;
    expect(revision).toBe("s12-m1791100000000");
    expect(await store.files.save("/home/cmux/notes.txt", "edited\n")).toBe(true);
    expect(ops(provider, CloudOps.fsWrite)[0].params).toEqual({
      machine: running().id,
      path: "/home/cmux/notes.txt",
      dataBase64: btoa("edited\n"),
      baseRevision: revision,
      idempotency_key: "k1",
    });
    // The file changed elsewhere: the next save with the old revision is a conflict, and nothing is lost.
    const stale = files(store).preview!.revision;
    await provider.call(CloudOps.fsWrite, {
      machine: running().id,
      path: "/home/cmux/notes.txt",
      dataBase64: btoa("other\n"),
      idempotency_key: "elsewhere",
    });
    expect(stale).toBeDefined();
    expect(await store.files.save("/home/cmux/notes.txt", "mine\n")).toBe(false);
    expect(store.getSnapshot().error).toBe("/home/cmux/notes.txt changed since it was read");
  });

  test("the mock refuses a write over 12 MiB with file_too_large, like the server", async () => {
    const provider = new MockCloudProvider();
    const big = btoa("x".repeat(12 * 1024 * 1024 + 1));
    await expect(
      provider.call(CloudOps.fsWrite, {
        machine: "vm_a1",
        path: "/home/cmux/big.txt",
        dataBase64: big,
        idempotency_key: "w",
      }),
    ).rejects.toMatchObject({
      code: "cmux.cloud.file_too_large",
      message: "the data is 12582913 bytes; the limit is 12582912 bytes",
    });
  });

  test("file_ops_busy shows the server's message in the banner and lists nothing new", async () => {
    const { provider, store } = await browsing();
    provider.fs.opsBusy = true;
    await store.files.open("/home/cmux/src");
    expect(store.getSnapshot().error).toBe("Other file ops are running: try again when one ends");
    expect(files(store).unavailable).toBeUndefined();
  });

  test("a failed write answers false so the editor keeps the text", async () => {
    const { provider, store } = await browsing();
    provider.failNext = CloudOps.fsWrite;
    expect(await store.files.save("/home/cmux/notes.txt", "draft\n")).toBe(false);
    expect(await store.files.save("/home/cmux/notes.txt", "draft\n")).toBe(true);
  });
});
