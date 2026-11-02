import { expect, test } from "bun:test";
import { FolderContinuation, folderContinuationRequest } from "../src/agent-session/acpmux/folderContinuation";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
function fixture() {
  const continuation = new FolderContinuation();
  const pending = deferred<string | undefined>();
  const events: string[] = [];
  let current = true;
  const actions = {
    start: () => {
      events.push("start");
      return pending.promise;
    },
    current: () => current,
    copyText: (id: string) => {
      events.push(`copy:${id}`);
    },
    select: async (id: string) => {
      events.push(`select:${id}`);
      return true;
    },
    clearFolder: () => {
      events.push("clear");
    },
  };
  return {
    continuation,
    pending,
    events,
    actions,
    navigate: () => {
      current = false;
    },
  };
}
test("double clicks create one chat and transfer only after start succeeds", async () => {
  const f = fixture();
  const first = f.continuation.run(f.actions);
  await f.continuation.run(f.actions);
  expect(f.events).toEqual(["start"]);
  f.pending.resolve("new");
  await first;
  expect(f.events).toEqual(["start", "copy:new", "select:new", "clear"]);
});
test("failed and empty starts never extract or restore a draft", async () => {
  const f = fixture();
  const first = f.continuation.run(f.actions);
  f.pending.reject(new Error("offline"));
  await expect(first).rejects.toThrow("offline");
  expect(f.events).toEqual(["start"]);
  await f.continuation.run({ ...f.actions, start: async () => undefined });
  expect(f.events).toEqual(["start"]);
});
for (const change of ["project", "session"] as const) {
  test(`late start after ${change} change leaves the newer composer untouched`, async () => {
    const f = fixture();
    const first = f.continuation.run(f.actions);
    if (change === "project") f.continuation.invalidate();
    else f.navigate();
    f.pending.resolve("old-destination");
    await first;
    expect(f.events).toEqual(["start"]);
  });
}
test("failed selection cancels the transfer and preserves the source", async () => {
  const f = fixture();
  const first = f.continuation.run({ ...f.actions, select: async () => false });
  f.pending.resolve("new");
  await first;
  expect(f.events).toEqual(["start", "copy:new"]);
});

test("navigation during selection cannot clear the newer folder", async () => {
  const f = fixture();
  const selection = deferred<boolean>();
  const first = f.continuation.run({ ...f.actions, select: () => selection.promise });
  f.pending.resolve("new");
  await Promise.resolve();
  selection.resolve(false);
  await first;
  expect(f.events).toEqual(["start", "copy:new"]);
});

test("a stale successful selection cannot clear the newer folder", async () => {
  const f = fixture();
  const selection = deferred<boolean>();
  const first = f.continuation.run({ ...f.actions, select: () => selection.promise });
  f.pending.resolve("new");
  await Promise.resolve();
  f.continuation.invalidate();
  selection.resolve(true);
  await first;
  expect(f.events).toEqual(["start", "copy:new"]);
});

test("recovery requests a folder-free chat without sending the held prompt", () => {
  expect(folderContinuationRequest).toEqual({ noProject: true, continueWithoutFolder: true });
});

for (const navigates of [false, true]) {
  test(`selection's own generation bump ${navigates ? "still fences later navigation" : "clears the recovered folder"}`, async () => {
    const continuation = new FolderContinuation();
    let clientGeneration = 1;
    let expectedGeneration = clientGeneration;
    let folder: string | undefined = "/declined";
    const selection = deferred<boolean>();
    const selecting = deferred<void>();
    const run = continuation.run({
      start: async () => "destination",
      current: () => clientGeneration === expectedGeneration,
      copyText: () => {},
      select: () => {
        // AcpmuxDirectClient.select changes the visit before its first await.
        clientGeneration += 1;
        expectedGeneration = clientGeneration;
        selecting.resolve();
        return selection.promise;
      },
      clearFolder: () => {
        folder = undefined;
      },
    });
    await selecting.promise;
    if (navigates) {
      clientGeneration += 1;
      folder = "/newer";
    }
    selection.resolve(true);
    await run;
    if (navigates) expect(folder).toBe("/newer");
    else expect(folder).toBeUndefined();
  });
}
