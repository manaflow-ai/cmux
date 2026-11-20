// A Find result opens the code editor at the matching line and column (plans/cmux-next/diff-host.md
// "Editor page"): a new tab's `cmux.editor.config` carries `location: {line, column}`, applied once
// with the file's load; a tab that already shows the file gets it on the `cmux.editor.reveal`
// stream. Either way the view moves the cursor there and centers the line.
import { expect, test } from "bun:test";
import type { FileLocation } from "../src/fileLocation";
import type { PageClient } from "../src/pages/shared/pageClient";
import { EDITOR_REVEAL } from "../src/pages/editor/host";
import { EditorStore, type CodeView, type EditorDocument } from "../src/pages/editor/store";

function harness(config: Record<string, unknown>) {
  const streams = new Map<string, (value: unknown) => void>();
  const client: PageClient = {
    async call<R>(op: string): Promise<R> {
      if (op === "cmux.editor.config") return config as R;
      throw new Error(`unexpected ${op}`);
    },
    async subscribe<E>(op: string, onEvent: (data: E, seq: number) => void) {
      streams.set(op, (value) => onEvent(value as E, 0));
      return () => {};
    },
    handle() {
      return () => {};
    },
  };
  const reveals: FileLocation[] = [];
  const loads: string[] = [];
  let text = "";
  const view: CodeView = {
    load(document: EditorDocument) {
      loads.push(document.path);
      text = document.text;
      if (document.location) reveals.push(document.location);
    },
    text: () => text,
    version: () => 1,
    setReadOnly() {},
    reveal(location) {
      reveals.push(location);
    },
  };
  return { store: new EditorStore(client), view, reveals, loads, streams };
}

const file = { path: "/w/a.ts", text: "one\ntwo\nthree\n", hash: "h" };

test("a config's location moves the cursor once the file is in the view", async () => {
  const { store, view, reveals, loads } = harness({ ...file, location: { line: 3, column: 2 } });
  store.attachView(view);
  await store.start();
  expect(loads).toEqual(["/w/a.ts"]);
  expect(reveals).toEqual([{ line: 3, column: 2 }]);
});

test("a config's location waits for a view that mounts after the load", async () => {
  const { store, view, reveals } = harness({ ...file, location: { line: 2, column: 1 } });
  await store.start();
  expect(reveals).toEqual([]);
  store.attachView(view);
  expect(reveals).toEqual([{ line: 2, column: 1 }]);
});

test("the reveal stream moves the cursor of a tab that already shows the file", async () => {
  const { store, view, reveals, streams } = harness(file);
  store.attachView(view);
  await store.start();
  expect(reveals).toEqual([]);
  streams.get(EDITOR_REVEAL)?.({ line: 2, column: 3 });
  expect(reveals).toEqual([{ line: 2, column: 3 }]);
});

test("a config without a location leaves the cursor alone; a malformed one is ignored", async () => {
  const { store, view, reveals, streams } = harness({ ...file, location: { line: 0, column: 1 } });
  store.attachView(view);
  await store.start();
  streams.get(EDITOR_REVEAL)?.({ line: "x" });
  expect(reveals).toEqual([]);
});

test("a recovered draft does not take the cursor off the config's location", async () => {
  const { store, view, reveals } = harness({
    ...file,
    recoveredText: "one\ntwo\nthree\nfour\n",
    location: { line: 3 },
  });
  const steps: string[] = [];
  const recording: CodeView = {
    ...view,
    load(document) {
      steps.push("load");
      view.load(document);
    },
    replaceText() {
      steps.push("replace");
    },
    reveal(location) {
      steps.push("reveal");
      view.reveal?.(location);
    },
  };
  store.attachView(recording);
  await store.start();
  expect(steps).toEqual(["load", "replace", "reveal"]);
  expect(reveals.at(-1)).toEqual({ line: 3 });
});
