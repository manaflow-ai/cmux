// The code editor and Markdown pages keep their tab's page while it holds edits not on disk:
// each store sets `user_edits` through `cmux.page.keepAlive` once when the first
// edit makes the file dirty, and ends it once the save lands. No call per keystroke.
import { expect, test } from "bun:test";
import { KEEP_ALIVE_OP, pageKeepAliveFor, type PageClient } from "../src/pages/shared/pageClient";
import { EditorStore, type CodeView, type EditorDocument, type Schedule } from "../src/pages/editor/store";
import { MarkdownStore } from "../src/pages/markdown/store";

type KeepCall = { reason: string; on: boolean };

function recordingClient(config: Record<string, unknown>, prefix: "cmux.editor" | "cmux.markdown") {
  const keep: KeepCall[] = [];
  const client = {
    async call<R>(op: string, params?: unknown): Promise<R> {
      if (op === KEEP_ALIVE_OP) {
        keep.push(params as KeepCall);
        return {} as R;
      }
      if (op === `${prefix}.config`) return config as R;
      if (op === `${prefix}.edited`) return { accepted: "kept" } as R;
      if (op === `${prefix}.save`) return { hash: "h2" } as R;
      throw new Error(`unexpected ${op}`);
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  } satisfies PageClient;
  return { client, keep };
}

// The autosave and the report window never end by themselves: the test saves.
const neverEnds: Schedule = () => () => {};

test("the editor sets user_edits once on its first edit and ends it when the save lands", async () => {
  const { client, keep } = recordingClient({ path: "/w/a.ts", text: "one\n", hash: "h" }, "cmux.editor");
  let text = "";
  let version = 1;
  const view: CodeView = {
    load(document: EditorDocument) {
      text = document.text;
    },
    text: () => text,
    version: () => version,
    setReadOnly() {},
  };
  const store = new EditorStore(client, neverEnds, neverEnds);
  store.attachView(view);
  await store.start();
  expect(keep).toEqual([]);
  for (const next of ["one\nt", "one\ntw", "one\ntwo\n"]) {
    text = next;
    version += 1;
    store.edited();
  }
  expect(keep).toEqual([{ reason: "user_edits", on: true }]);
  await store.save();
  expect(keep).toEqual([
    { reason: "user_edits", on: true },
    { reason: "user_edits", on: false },
  ]);
});

test("the Markdown page sets user_edits once on its first edit and ends it when the save lands", async () => {
  const { client, keep } = recordingClient(
    { path: "/a.md", text: "# A\n", hash: "h", assetBase: "/assets/" },
    "cmux.markdown",
  );
  const store = new MarkdownStore(client, neverEnds, neverEnds);
  await store.start();
  store.setMode("source");
  expect(keep).toEqual([]);
  store.setSource("# A\nf");
  store.setSource("# A\nfi");
  store.setSource("# A\nfirst\n");
  expect(keep).toEqual([{ reason: "user_edits", on: true }]);
  await store.save();
  expect(store.getState().status).toBe("saved");
  expect(keep).toEqual([
    { reason: "user_edits", on: true },
    { reason: "user_edits", on: false },
  ]);
});

// The page's automatic edits (pageEdits.ts) share the store's keep-alive: typing set `user_edits`
// before the store saw an edit, and the store's save ends it, so a saved file never keeps its page.
test("the editor's save ends the page's automatic user_edits too", async () => {
  const { client, keep } = recordingClient({ path: "/w/a.ts", text: "one\n", hash: "h" }, "cmux.editor");
  let text = "";
  let version = 1;
  const view: CodeView = {
    load(document: EditorDocument) {
      text = document.text;
    },
    text: () => text,
    version: () => version,
    setReadOnly() {},
  };
  const store = new EditorStore(client, neverEnds, neverEnds);
  store.attachView(view);
  await store.start();
  pageKeepAliveFor(client).set("user_edits", true, {}); // the watcher heard the first key
  text = "one\ntwo\n";
  version += 1;
  store.edited();
  await store.save();
  expect(keep).toEqual([
    { reason: "user_edits", on: true },
    { reason: "user_edits", on: false },
  ]);
});
