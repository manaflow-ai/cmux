import { expect, test } from "bun:test";
import { MAX_SOURCE_USES, SourceUses, type SourceUse, type SourceUsesClient, type SourceUsesPage } from "./sourceUses";
import { MarkdownStore } from "./store";
import type { PageClient } from "../shared/pageClient";

const use: SourceUse = {
  seq: 1,
  at: 1_795_158_000_000,
  turnId: "turn",
  replyId: "turn.boot.1",
  toolCallId: "read",
  kind: "file",
  uri: "file:///a.md",
};
const page = (uses: SourceUse[] = [use], nextCursor: string | null = null): SourceUsesPage => ({
  sessionId: "captured-chat",
  uri: "file:///a.md",
  uses,
  nextCursor,
});

test("the disclosure stops at its bounded served-reply window", async () => {
  let calls = 0;
  const client: SourceUsesClient = {
    async call<R>() {
      calls += 1;
      return page(
        Array.from({ length: MAX_SOURCE_USES + 1 }, (_, seq) => ({ ...use, seq })),
        "more",
      ) as R;
    },
  };
  const model = new SourceUses(client, "/a.md");
  await model.load();
  expect(model.getState().uses).toHaveLength(MAX_SOURCE_USES);
  expect(model.getState()).toMatchObject({ capped: true, nextCursor: null });
  await model.load();
  expect(calls).toBe(1);
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

test("source-use queries are on demand and an empty cursor page remains pageable", async () => {
  const calls: unknown[] = [];
  const client: SourceUsesClient = {
    async call<R>(op: string, params: unknown) {
      calls.push({ op, params });
      return (calls.length === 1 ? page([], "next-1") : page()) as R;
    },
  };
  const model = new SourceUses(client, "/a.md");
  expect(calls).toHaveLength(0);
  await model.load();
  expect(model.getState()).toMatchObject({ loaded: true, uses: [], nextCursor: "next-1" });
  await model.load();
  expect(calls[1]).toEqual({ op: "cmux.markdown.sourceUses", params: { path: "/a.md", cursor: "next-1" } });
  expect(model.getState().uses).toEqual([use]);
  await model.load();
  expect(calls).toHaveLength(2);
});

test("navigation and same-file context replacement discard stale query completions", async () => {
  for (const nextPath of ["/b.md", "/a.md"]) {
    const old = deferred<SourceUsesPage>();
    let count = 0;
    const client: SourceUsesClient = {
      async call<R>() {
        return (count++ === 0 ? await old.promise : page([], null)) as R;
      },
    };
    const model = new SourceUses(client, "/a.md");
    const pending = model.load();
    model.setDocument(nextPath);
    await model.load();
    old.resolve(page());
    await pending;
    expect(model.getState()).toMatchObject({ loaded: true, uses: [], nextCursor: null, error: false });
  }
});

test("a stale reveal failure does not mark the next document, and the page sends no session choice", async () => {
  const old = deferred<unknown>();
  const calls: unknown[] = [];
  const client: SourceUsesClient = {
    async call<R>(op: string, params: unknown) {
      calls.push({ op, params });
      return (op === "cmux.markdown.sourceUses" ? page() : await old.promise) as R;
    },
  };
  const model = new SourceUses(client, "/a.md");
  await model.load();
  const revealing = model.reveal(model.getState().uses[0]!);
  expect(calls[1]).toEqual({
    op: "cmux.markdown.revealSourceUse",
    params: { path: "/a.md", replyId: "turn.boot.1", turnId: "turn" },
  });
  model.setDocument("/b.md");
  old.reject(new Error("late failure"));
  await revealing;
  expect(model.getState()).toMatchObject({ uses: [], revealing: false, revealError: false });
});

test("disposed contexts query nothing and cannot reveal rows they did not receive", async () => {
  let calls = 0;
  const client: SourceUsesClient = {
    async call<R>() {
      calls += 1;
      return page() as R;
    },
  };
  const model = new SourceUses(client, undefined);
  await model.load();
  await model.reveal(use);
  expect(calls).toBe(0);
  model.setDocument("/a.md");
  await model.reveal(use);
  expect(calls).toBe(0);
  await model.load();
  model.dispose();
  await model.load();
  await model.reveal(use);
  expect(calls).toBe(1);
});

test("context refresh preserves unsaved Markdown and rejects another file's command", async () => {
  const calls: string[] = [];
  const client: PageClient = {
    async call<R>(op: string, params: unknown) {
      calls.push(op);
      if (op === "cmux.markdown.open") return { path: (params as { path: string }).path, text: "# B", hash: "b" } as R;
      return { path: "/a.md", text: "# A", hash: "a", sourceUses: true, sourceContext: "old-chat" } as R;
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  };
  const noSchedule = () => () => {};
  const store = new MarkdownStore(client, noSchedule, noSchedule);
  await store.start();
  store.setMode("source");
  store.setSource("# Unsaved edit");
  const previous = store.getState();
  const count = calls.length;
  store.updateSourceContext({ path: "/other.md", sourceUses: true, sourceContext: "wrong" });
  expect(store.getState()).toBe(previous);
  store.updateSourceContext({ path: "/a.md", sourceUses: true, sourceContext: "new-chat" });
  expect(store.getState()).toMatchObject({ source: "# Unsaved edit", status: "edited", revision: previous.revision });
  expect(store.getState().config?.sourceContext).toBe("new-chat");
  expect(calls).toHaveLength(count);
});

test("following a document link does not carry the previous file's source context", async () => {
  const client: PageClient = {
    async call<R>(op: string) {
      return (
        op === "cmux.markdown.config"
          ? { path: "/a.md", text: "# A", hash: "a", sourceUses: true, sourceContext: "chat" }
          : { path: "/b.md", text: "# B", hash: "b" }
      ) as R;
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  };
  const store = new MarkdownStore(client);
  await store.start();
  await store.navigate("/b.md", "", 0);
  expect(store.getState().config?.sourceUses).toBeUndefined();
  expect(store.getState().config?.sourceContext).toBeUndefined();
});
