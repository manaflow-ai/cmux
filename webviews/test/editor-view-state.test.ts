// A hidden code editor tab's page may be discarded (`memoryDiscardInternalPages`):
// right before, the host asks `cmux.editor.viewState`; the page reports any edit it has not
// reported yet (so the host keeps a tab with unsaved edits) and answers Monaco's view state. The
// next page gets it back as the config's `viewState`, applied once the file is in the view and
// before a `reveal`.
import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { EditorStore, type CodeView, type EditorDocument, type Schedule } from "../src/pages/editor/store";

const file = { path: "/w/a.ts", text: "one\ntwo\nthree\n", hash: "h" };

function harness(config: Record<string, unknown>) {
  const edits: string[] = [];
  const client = {
    async call<R>(op: string, params?: unknown): Promise<R> {
      if (op === "cmux.editor.config") return config as R;
      if (op === "cmux.editor.edited") {
        edits.push((params as { text: string }).text);
        return { accepted: "kept" } as R;
      }
      throw new Error(`unexpected ${op}`);
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  } satisfies PageClient;
  const calls: string[] = [];
  let text = "";
  let version = 1;
  const view: CodeView = {
    load(document: EditorDocument) {
      calls.push(`load ${document.path}`);
      text = document.text;
    },
    text: () => text,
    version: () => version,
    setReadOnly() {},
    reveal(position) {
      calls.push(`reveal ${position.line}:${position.column}`);
    },
    saveViewState: () => ({ cursorState: [{ line: 2 }], viewState: { scrollTop: 40 }, contributionsState: {} }),
    restoreViewState(state) {
      calls.push(`restore ${JSON.stringify(state)}`);
    },
  };
  const type = (next: string) => {
    text = next;
    version += 1;
  };
  // The report window never ends by itself: only the first edit and a flush send.
  const neverEnds: Schedule = () => () => {};
  const store = new EditorStore(client, neverEnds, neverEnds);
  return { store, view, calls, edits, type };
}

test("a config's viewState goes back into the view once, before its reveal", async () => {
  const saved = { cursorState: [{ line: 3 }], viewState: { scrollTop: 120 }, contributionsState: {} };
  const { store, view, calls } = harness({ ...file, viewState: saved, reveal: { line: 1, column: 1 } });
  store.attachView(view);
  await store.start();
  expect(calls).toEqual(["load /w/a.ts", `restore ${JSON.stringify(saved)}`, "reveal 1:1"]);
  store.attachView(view);
  expect(calls.filter((call) => call.startsWith("restore"))).toHaveLength(1);
});

test("a config without viewState leaves the view where it loads", async () => {
  const { store, view, calls } = harness(file);
  store.attachView(view);
  await store.start();
  expect(calls).toEqual(["load /w/a.ts"]);
});

test("viewState answers the view's state and reports a coalesced edit first", async () => {
  const { store, view, edits, type } = harness(file);
  store.attachView(view);
  await store.start();
  type("one\n");
  store.edited();
  type("one\ntwo\n");
  store.edited();
  expect(edits).toEqual(["one\n"]);
  const state = store.viewState();
  expect(edits).toEqual(["one\n", "one\ntwo\n"]);
  expect((state.view as { viewState: { scrollTop: number } }).viewState.scrollTop).toBe(40);
  expect(state.dirty).toBe(true);
  store.viewState();
  expect(edits).toHaveLength(2);
});

test("viewState says the page holds no edits while its text is on disk", async () => {
  const { store, view } = harness(file);
  store.attachView(view);
  await store.start();
  expect(store.viewState().dirty).toBe(false);
});

test("viewState with no view answers no state and no edits", () => {
  const { store } = harness(file);
  expect(store.viewState()).toEqual({ dirty: false, view: null });
});
