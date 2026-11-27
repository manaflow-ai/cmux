// A key that leaves the editor's status where it was must not write state: each write wakes
// every subscriber, so a run of keys in an already edited file would re-render per key. The
// editor page and the Markdown viewer each had the write.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { EDITOR_CONFIG_OP } from "../src/pages/editor/host";
import { EditorStore, type CodeView } from "../src/pages/editor/store";
import { MARKDOWN_CONFIG_OP } from "../src/pages/markdown/host";
import { MarkdownStore, type Schedule } from "../src/pages/markdown/store";
import type { PageClient } from "../src/pages/shared/pageClient";

test("a key that leaves the editor status unchanged writes nothing", async () => {
  const dom = new JSDOM("<!doctype html><body></body>");
  const previous = globalThis.document;
  globalThis.document = dom.window.document as unknown as Document;
  try {
    const client = {
      call: async (op: string) =>
        op === EDITOR_CONFIG_OP ? { path: "/w/a.ts", text: "a\n", hash: "h1", settings: { autoSave: "off" } } : null,
      subscribe: async () => () => {},
      handle: () => () => {},
    } as unknown as PageClient;
    const store = new EditorStore(client);
    let version = 1;
    const view: CodeView = {
      load: () => {},
      text: () => "a\n",
      version: () => version,
      setReadOnly: () => {},
      prepareSave: async () => {},
    };
    store.attachView(view);
    await store.start();
    version += 1;
    store.edited();
    expect(store.getState().status).toBe("edited");
    const before = store.getState();
    let writes = 0;
    store.subscribe(() => (writes += 1));
    version += 1;
    store.edited();
    version += 1;
    store.edited();
    expect(writes).toBe(0);
    expect(store.getState()).toBe(before);
  } finally {
    globalThis.document = previous;
  }
});

test("a key in an already edited Markdown file writes nothing", async () => {
  const client = {
    call: async (op: string) =>
      op === MARKDOWN_CONFIG_OP ? { path: "/w/a.md", text: "a\n", hash: "h1", assetBase: "/assets/" } : null,
    subscribe: async () => () => {},
    handle: () => () => {},
  } as unknown as PageClient;
  const never: Schedule = () => () => {};
  const store = new MarkdownStore(client, never, never);
  await store.start();
  store.edited();
  expect(store.getState().status).toBe("edited");
  const before = store.getState();
  let writes = 0;
  store.subscribe(() => (writes += 1));
  store.edited();
  store.edited();
  expect(writes).toBe(0);
  expect(store.getState()).toBe(before);
});
