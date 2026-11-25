// The Forum page's store over the daemon's forum ops (cmux-tui-core server/forum_routed.rs),
// against the in-memory mock: the first read, opening a thread, a reply and a post re-reading,
// a mutation carrying its idempotency key, and a failed read showing the page offline.
import { expect, test } from "bun:test";
import { pageError, type PageClient } from "../src/pages/shared/pageClient";
import { MockForumProvider } from "../src/pages/forum/mockProvider";
import { ForumOps, ForumStore } from "../src/pages/forum/store";

const keys = () => {
  let n = 0;
  return () => `k${++n}`;
};

test("reads the snapshot when the page subscribes", async () => {
  const mock = new MockForumProvider();
  const store = new ForumStore(mock, { newKey: keys() });
  expect(store.getState().snapshot.status).toBe("loading");
  store.subscribe(() => undefined);
  await store.reload();
  expect(store.getState().snapshot.status).toBe("ready");
  expect(store.getState().snapshot.threads.length).toBeGreaterThan(0);
  expect(mock.calls[0]?.op).toBe(ForumOps.snapshot);
});

test("opening a thread reads its comments; a reply sends a key and re-reads it", async () => {
  const mock = new MockForumProvider();
  const store = new ForumStore(mock, { newKey: keys() });
  await store.reload();
  const number = store.getState().snapshot.threads[0]!.number;
  await store.openThread(number);
  const before = store.getState().snapshot.comments[number]?.length ?? 0;
  await store.reply(number, "Seen it too");
  expect(store.getState().snapshot.comments[number]?.length).toBe(before + 1);
  const reply = mock.calls.find((c) => c.op === ForumOps.reply);
  expect(reply?.params).toEqual({ number, body: "Seen it too", idempotency_key: "k1" });
});

test("a post lands in the list", async () => {
  const mock = new MockForumProvider();
  const store = new ForumStore(mock, { newKey: keys() });
  await store.reload();
  const number = await store.post({ space: "fleet", kind: "finding", title: "New", body: "Body" });
  expect(number).not.toBeNull();
  expect(store.getState().snapshot.threads.some((t) => t.number === number && t.title === "New")).toBe(true);
});

test("a failed first read shows the page offline with the message", async () => {
  const failing: PageClient = {
    call: async () => {
      throw pageError("cmux.operation.failed", "The hosted forum could not be reached");
    },
    subscribe: async () => () => undefined,
    handle: () => () => undefined,
  };
  const store = new ForumStore(failing);
  await store.reload();
  expect(store.getState().snapshot.status).toBe("ready");
  expect(store.getState().snapshot.feed).toBe("offline");
  expect(store.getState().error).toBeTruthy();
});

test("the daemon's signed-out answer shows the gate", async () => {
  const client: PageClient = {
    call: async <R>() =>
      ({ status: "signed-out", team: "", feed: "offline", spaces: [], threads: [], comments: {} }) as R,
    subscribe: async () => () => undefined,
    handle: () => () => undefined,
  };
  const store = new ForumStore(client);
  await store.reload();
  expect(store.getState().snapshot.status).toBe("signed-out");
});
