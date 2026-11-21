// Codex's review of #39247 at f02e048 (F2): a file tab's host hold now ends at a successful save,
// so the page itself must say it holds unsaved text from the edit until its text is on disk
// (edited, saving, a failed save), and stop saying so once it is.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { EDITOR_CONFIG_OP, EDITOR_SAVE_OP } from "../src/pages/editor/host";
import { EditorStore, type CodeView } from "../src/pages/editor/store";
import type { PageClient } from "../src/pages/shared/pageClient";
import { UNSAVED_EDITS_ATTRIBUTE } from "../src/pages/shared/pageHealth";

test("the editor marks the document from the edit until its text is saved", async () => {
  const dom = new JSDOM("<!doctype html><body></body>");
  const previous = globalThis.document;
  globalThis.document = dom.window.document as unknown as Document;
  try {
    let finishWrite!: () => void;
    const client = {
      call: async (op: string) => {
        if (op === EDITOR_CONFIG_OP) return { path: "/w/a.ts", text: "a\n", hash: "h1", settings: {} };
        if (op === EDITOR_SAVE_OP) {
          await new Promise<void>((done) => (finishWrite = done));
          return { hash: "h2" };
        }
        return null;
      },
      subscribe: async () => () => {},
      handle: () => () => {},
    } as unknown as PageClient;
    const store = new EditorStore(client);
    let text = "a\n";
    let version = 1;
    const view: CodeView = {
      load: () => {},
      text: () => text,
      version: () => version,
      setReadOnly: () => {},
      prepareSave: async () => {},
    };
    store.attachView(view);
    await store.start();
    const marked = () => dom.window.document.documentElement.hasAttribute(UNSAVED_EDITS_ATTRIBUTE);
    expect(marked()).toBe(false);
    text = "b\n";
    version += 1;
    store.edited();
    expect(marked()).toBe(true);
    const saving = store.save();
    await Promise.resolve();
    // Still not on disk while the write runs.
    expect(marked()).toBe(true);
    finishWrite();
    await saving;
    expect(store.getState().status).toBe("saved");
    expect(marked()).toBe(false);
  } finally {
    globalThis.document = previous;
  }
});
