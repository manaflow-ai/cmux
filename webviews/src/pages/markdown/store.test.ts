import { describe, expect, test } from "bun:test";
import { pageError, type PageClient } from "../shared/pageClient";
import { MARKDOWN_CHANGES, MARKDOWN_CONFLICT, type MarkdownChange } from "./host";
import type { SourceMap } from "./sourceMap";
import { MarkdownStore, type DocumentEditor } from "./store";

/** A host with one file: saves check the hash, and the test pushes disk changes. */
class FakeHost implements PageClient {
  text: string;
  hash: string;
  saves: Array<{ text: string; baseHash: string | null }> = [];
  readOnly = false;
  private onChange: ((change: MarkdownChange, seq: number) => void) | null = null;
  constructor(text: string) {
    this.text = text;
    this.hash = `h:${text}`;
  }
  async call<R>(op: string, params: unknown): Promise<R> {
    if (op === "cmux.markdown.config") {
      return { path: "/w/a.md", text: this.text, hash: this.hash, readOnly: this.readOnly } as R;
    }
    if (op === "cmux.markdown.save") {
      const { text, baseHash } = params as { text: string; baseHash: string | null };
      this.saves.push({ text, baseHash });
      if (baseHash !== this.hash)
        throw pageError(MARKDOWN_CONFLICT, "conflict", false, { hash: this.hash, text: this.text });
      this.text = text;
      this.hash = `h:${text}`;
      return { hash: this.hash } as R;
    }
    throw pageError("cmux.protocol.unknown_op", op);
  }
  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream === MARKDOWN_CHANGES) this.onChange = onEvent as never;
    return () => {};
  }
  handle(): () => void {
    return () => {};
  }
  diskWrite(text: string): void {
    this.text = text;
    this.hash = `h:${text}`;
    this.onChange?.({ path: "/w/a.md", hash: this.hash, text }, 1);
  }
}

/** An editor whose document is plain text. */
class FakeEditor implements DocumentEditor {
  text = "";
  loads = 0;
  readOnly = false;
  load(text: string): void {
    this.text = text;
    this.loads++;
  }
  snapshot(): SourceMap {
    return { text: this.text, blocks: [] };
  }
  commit(): void {}
  setReadOnly(readOnly: boolean): void {
    this.readOnly = readOnly;
  }
}

function setup(text = "# A\n") {
  const host = new FakeHost(text);
  const timers: Array<() => void> = [];
  const store = new MarkdownStore(host, (run) => {
    timers.push(run);
    return () => timers.splice(timers.indexOf(run), 1);
  });
  const editor = new FakeEditor();
  store.attachEditor(editor);
  const flush = async () => {
    for (const run of timers.splice(0)) run();
    await new Promise((resolve) => setTimeout(resolve, 0));
  };
  return { host, store, editor, timers, flush };
}

describe("MarkdownStore", () => {
  test("loading never saves; an edit autosaves after the pause", async () => {
    const { host, store, editor, timers, flush } = setup();
    await store.start();
    expect(editor.text).toBe("# A\n");
    expect(timers.length).toBe(0);
    editor.text = "# B\n";
    store.edited();
    expect(store.getState().status).toBe("edited");
    await flush();
    expect(host.saves).toEqual([{ text: "# B\n", baseHash: "h:# A\n" }]);
    expect(store.getState().status).toBe("saved");
  });

  test("an edit back to the saved text writes nothing", async () => {
    const { host, store, editor, flush } = setup();
    await store.start();
    editor.text = "# A\n";
    store.edited();
    await flush();
    expect(host.saves.length).toBe(0);
    expect(store.getState().status).toBe("saved");
  });

  test("a disk change without local edits reloads; its own save echo is ignored", async () => {
    const { host, store, editor, flush } = setup();
    await store.start();
    editor.text = "# B\n";
    store.edited();
    await flush();
    const loads = editor.loads;
    host.diskWrite("# B\n");
    expect(editor.loads).toBe(loads);
    host.diskWrite("# C\n");
    expect(editor.text).toBe("# C\n");
    expect(store.getState().conflict).toBe(null);
  });

  test("a disk change with local edits raises a conflict; keep mine overwrites with the new hash", async () => {
    const { host, store, editor, flush } = setup();
    await store.start();
    editor.text = "# Mine\n";
    store.edited();
    host.diskWrite("# Theirs\n");
    expect(store.getState().conflict?.text).toBe("# Theirs\n");
    await flush();
    expect(host.saves.length).toBe(0);
    await store.keepMine();
    expect(host.saves.at(-1)).toEqual({ text: "# Mine\n", baseHash: "h:# Theirs\n" });
    expect(host.text).toBe("# Mine\n");
  });

  test("reload from disk drops local edits", async () => {
    const { host, store, editor } = setup();
    await store.start();
    editor.text = "# Mine\n";
    store.edited();
    host.diskWrite("# Theirs\n");
    store.reloadFromDisk();
    expect(editor.text).toBe("# Theirs\n");
    expect(store.getState().conflict).toBe(null);
    expect(store.getState().status).toBe("saved");
  });

  test("a save refused on a hash conflict shows the banner", async () => {
    const { host, store, editor } = setup();
    await store.start();
    host.text = "# Changed behind the watcher\n";
    host.hash = `h:${host.text}`;
    editor.text = "# Mine\n";
    store.edited();
    await store.save();
    expect(store.getState().conflict?.text).toBe("# Changed behind the watcher\n");
    expect(host.text).toBe("# Changed behind the watcher\n");
  });

  test("read only never saves", async () => {
    const { host, store, editor, flush } = setup();
    host.readOnly = true;
    await store.start();
    expect(editor.readOnly).toBe(true);
    editor.text = "# B\n";
    store.edited();
    await flush();
    await store.save();
    expect(host.saves.length).toBe(0);
  });

  test("source mode edits save, and rich text reloads only when the source changed", async () => {
    const { host, store, editor, flush } = setup();
    await store.start();
    const loads = editor.loads;
    store.setMode("source");
    store.setMode("rich");
    expect(editor.loads).toBe(loads);
    store.setMode("source");
    store.setSource("# Source\n");
    await flush();
    expect(host.text).toBe("# Source\n");
    store.setMode("rich");
    expect(editor.text).toBe("# Source\n");
  });
});
