// A Find result opens the code editor at the matching line and column (plans/cmux-next/diff-host.md
// "Editor page"): a new tab's `cmux.editor.config` carries `reveal: {line, column}`, applied once
// after the file loads; a tab that already shows the file gets the `reveal` page command with
// `text` "line:column". Either way the view moves the cursor there and centers the line.
import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { revealPosition } from "../src/pages/editor/keys";
import { EditorStore, type CodeView, type EditorDocument } from "../src/pages/editor/store";

function harness(config: Record<string, unknown>) {
  const client = {
    async call<R>(op: string): Promise<R> {
      if (op === "cmux.editor.config") return config as R;
      throw new Error(`unexpected ${op}`);
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  } satisfies PageClient;
  const reveals: { line: number; column: number }[] = [];
  const loads: string[] = [];
  let text = "";
  const view: CodeView = {
    load(document: EditorDocument) {
      loads.push(document.path);
      text = document.text;
    },
    text: () => text,
    version: () => 1,
    setReadOnly() {},
    reveal(position) {
      reveals.push(position);
    },
  };
  return { store: new EditorStore(client), view, reveals, loads };
}

const file = { path: "/w/a.ts", text: "one\ntwo\nthree\n", hash: "h" };

test("a config's reveal moves the cursor once the file is in the view", async () => {
  const { store, view, reveals, loads } = harness({ ...file, reveal: { line: 3, column: 2 } });
  store.attachView(view);
  await store.start();
  expect(loads).toEqual(["/w/a.ts"]);
  expect(reveals).toEqual([{ line: 3, column: 2 }]);
});

test("a config's reveal waits for a view that mounts after the load", async () => {
  const { store, view, reveals } = harness({ ...file, reveal: { line: 2, column: 1 } });
  await store.start();
  expect(reveals).toEqual([]);
  store.attachView(view);
  expect(reveals).toEqual([{ line: 2, column: 1 }]);
});

test("the reveal command moves the cursor of a tab that already shows the file", async () => {
  const { store, view, reveals } = harness(file);
  store.attachView(view);
  await store.start();
  expect(reveals).toEqual([]);
  store.reveal(revealPosition("2:3"));
  expect(reveals).toEqual([{ line: 2, column: 3 }]);
});

test("a config without reveal leaves the cursor alone", async () => {
  const { store, view, reveals } = harness(file);
  store.attachView(view);
  await store.start();
  expect(reveals).toEqual([]);
});

test("the reveal text is line:column, 1-based; a malformed one is ignored", () => {
  expect(revealPosition("12:5")).toEqual({ line: 12, column: 5 });
  expect(revealPosition("12")).toEqual({ line: 12, column: 1 });
  expect(revealPosition("0:1")).toBeNull();
  expect(revealPosition("x:y")).toBeNull();
  expect(revealPosition(undefined)).toBeNull();
});
