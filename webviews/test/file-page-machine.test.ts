// A file of a Cloud workspace (#25581) is read from its machine. When that machine cannot answer,
// the code editor and the Markdown page say why in the host's words (not a generic failure), and
// a machine that drops off while the file is open shows a notice above it without touching the
// text; the notice clears when the machine answers again.
import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { EDITOR_UNAVAILABLE, type EditorChange } from "../src/pages/editor/host";
import { EditorStore, type CodeView, type EditorDocument } from "../src/pages/editor/store";
import { MARKDOWN_UNAVAILABLE, type MarkdownChange } from "../src/pages/markdown/host";
import { MarkdownStore } from "../src/pages/markdown/store";

const OFFLINE = "“dev-vm” is not connected. The file shows again when it reconnects.";

function pageError(code: string, message: string): Error {
  return Object.assign(new Error(message), { code, retryable: true });
}

/** A host whose config answers `config` (or throws it), and whose changes stream the test drives. */
function host(config: unknown) {
  let emit: ((change: unknown) => void) | undefined;
  const client = {
    async call<R>(op: string): Promise<R> {
      if (op.endsWith(".config")) {
        if (config instanceof Error) throw config;
        return config as R;
      }
      throw Object.assign(new Error(op), { code: "cmux.protocol.unknown_op" });
    },
    async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      if (stream.endsWith(".changes")) emit = (change) => onEvent(change as E, 0);
      return () => {};
    },
    handle() {
      return () => {};
    },
  } satisfies PageClient;
  return { client, change: (change: unknown) => emit?.(change) };
}

function editorView(): { view: CodeView; loads: string[] } {
  const loads: string[] = [];
  let text = "";
  return {
    loads,
    view: {
      load(document: EditorDocument) {
        loads.push(document.text);
        text = document.text;
      },
      text: () => text,
      version: () => 1,
      setReadOnly() {},
      reveal() {},
    },
  };
}

test("the editor says the machine is offline when its file cannot open", async () => {
  const { client } = host(pageError(EDITOR_UNAVAILABLE, OFFLINE));
  const store = new EditorStore(client);
  await store.start();
  expect(store.getState().phase).toBe("failed");
  expect(store.getState().failure).toBe(OFFLINE);
});

test("the editor keeps the generic failure for any other error", async () => {
  const { client } = host(pageError("cmux.editor.too_large", "/w/big.log"));
  const store = new EditorStore(client);
  await store.start();
  expect(store.getState().phase).toBe("failed");
  expect(store.getState().failure).toBeNull();
});

test("the editor shows a notice while the file's machine is away, and keeps the text", async () => {
  const { client, change } = host({ path: "/home/cmux/a.ts", text: "one\n", hash: "h1" });
  const store = new EditorStore(client);
  const { view, loads } = editorView();
  store.attachView(view);
  await store.start();
  change({ path: "/home/cmux/a.ts", hash: null, unavailable: OFFLINE } satisfies EditorChange);
  expect(store.getState().unavailable).toBe(OFFLINE);
  expect(store.getState().conflict).toBeNull();
  expect(loads).toEqual(["one\n"]);
  change({ path: "/home/cmux/a.ts", hash: null, unavailable: null } satisfies EditorChange);
  expect(store.getState().unavailable).toBeNull();
  // A real change of the file still arrives as before.
  change({ path: "/home/cmux/a.ts", hash: "h2", text: "two\n" } satisfies EditorChange);
  expect(loads).toEqual(["one\n", "two\n"]);
});

test("the Markdown page says the machine is offline, and shows the notice without a conflict", async () => {
  const offline = new MarkdownStore(host(pageError(MARKDOWN_UNAVAILABLE, OFFLINE)).client);
  await offline.start();
  expect(offline.getState().phase).toBe("failed");
  expect(offline.getState().failure).toBe(OFFLINE);

  const { client, change } = host({ path: "/home/cmux/notes.md", text: "# Notes\n", hash: "h1" });
  const store = new MarkdownStore(client);
  await store.start();
  expect(store.getState().phase).toBe("ready");
  change({ path: "/home/cmux/notes.md", hash: null, unavailable: OFFLINE } satisfies MarkdownChange);
  expect(store.getState().unavailable).toBe(OFFLINE);
  expect(store.getState().conflict).toBeNull();
  change({ path: "/home/cmux/notes.md", hash: null, unavailable: null } satisfies MarkdownChange);
  expect(store.getState().unavailable).toBeNull();
});
