import { describe, expect, test } from "bun:test";
import { pageError, type PageClient } from "../shared/pageClient";
import { EDITOR_CHANGES, EDITOR_CONFLICT, EDITOR_LOOK, type EditorChange, type EditorLook } from "./host";
import { EditorStore, withSetting, type CodeView, type EditorDocument } from "./store";

/** A host with one file: saves check the hash; the test pushes disk changes and looks. */
class FakeHost implements PageClient {
  text: string;
  hash: string;
  saves: Array<{ text: string; baseHash: string | null }> = [];
  preferences: Array<{ key: string; value: unknown }> = [];
  readOnly = false;
  settings: unknown = { autoSave: "off" };
  private onChange: ((change: EditorChange, seq: number) => void) | null = null;
  private onLook: ((look: EditorLook, seq: number) => void) | null = null;
  constructor(text: string) {
    this.text = text;
    this.hash = `h:${text}`;
  }
  async call<R>(op: string, params: unknown): Promise<R> {
    if (op === "cmux.editor.config") {
      return {
        path: "/w/a.ts",
        text: this.text,
        hash: this.hash,
        readOnly: this.readOnly,
        readOnlyReason: this.readOnly ? "outside" : undefined,
        settings: this.settings,
      } as R;
    }
    if (op === "cmux.editor.save") {
      const { text, baseHash } = params as { text: string; baseHash: string | null };
      this.saves.push({ text, baseHash });
      if (baseHash !== this.hash)
        throw pageError(EDITOR_CONFLICT, "conflict", false, { hash: this.hash, text: this.text });
      this.text = text;
      this.hash = `h:${text}`;
      return { hash: this.hash } as R;
    }
    if (op === "cmux.editor.setPreference") {
      this.preferences.push(params as { key: string; value: unknown });
      return {} as R;
    }
    throw pageError("cmux.protocol.unknown_op", op);
  }
  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream === EDITOR_CHANGES) this.onChange = onEvent as never;
    if (stream === EDITOR_LOOK) this.onLook = onEvent as never;
    return () => {};
  }
  handle(): () => void {
    return () => {};
  }
  diskWrite(text: string): void {
    this.text = text;
    this.hash = `h:${text}`;
    this.onChange?.({ path: "/w/a.ts", hash: this.hash, text }, 1);
  }
  look(look: EditorLook): void {
    this.onLook?.(look, 1);
  }
}

/** A view whose document is a string; the version counts edits and returns on undo. */
class FakeView implements CodeView {
  body = "";
  loads = 0;
  readOnly = false;
  private history: string[] = [];
  load(document: EditorDocument): void {
    this.body = document.text;
    this.history = [document.text];
    this.loads++;
  }
  text(): string {
    return this.body;
  }
  version(): number {
    // Like Monaco's alternative version id: text it had before gets that version back.
    return this.history.indexOf(this.body) + 1;
  }
  setReadOnly(readOnly: boolean): void {
    this.readOnly = readOnly;
  }
  type(text: string): void {
    this.body = text;
    this.history.push(text);
  }
}

async function ready(text: string, configure?: (host: FakeHost) => void) {
  const host = new FakeHost(text);
  configure?.(host);
  const scheduled: Array<() => void> = [];
  const store = new EditorStore(host, (run) => {
    scheduled.push(run);
    return () => scheduled.splice(scheduled.indexOf(run), 1);
  });
  const view = new FakeView();
  store.attachView(view);
  await store.start();
  return { host, store, view, scheduled };
}

describe("EditorStore", () => {
  test("loads the file into the view, byte for byte", async () => {
    const { store, view } = await ready("﻿a\r\nb");
    expect(store.getState().phase).toBe("ready");
    expect(view.body).toBe("﻿a\r\nb");
  });

  test("a save without an edit writes nothing", async () => {
    const { host, store } = await ready("a\n");
    await store.save();
    expect(host.saves).toEqual([]);
  });

  test("an edit undone back to the file writes nothing", async () => {
    const { host, store, view } = await ready("a\n");
    view.type("ab\n");
    store.edited();
    view.type("a\n");
    store.edited();
    expect(store.getState().status).toBe("saved");
    await store.save();
    expect(host.saves).toEqual([]);
  });

  test("an edit saves with the base hash and the view's exact text", async () => {
    const { host, store, view } = await ready("a\r\n");
    view.type("ab\r\n");
    store.edited();
    expect(store.getState().status).toBe("edited");
    await store.save();
    expect(host.saves).toEqual([{ text: "ab\r\n", baseHash: "h:a\r\n" }]);
    expect(store.getState().status).toBe("saved");
    expect(store.isDirty()).toBe(false);
  });

  test("autoSave afterDelay schedules a save after an edit; off does not", async () => {
    const off = await ready("a");
    off.view.type("b");
    off.store.edited();
    expect(off.scheduled.length).toBe(0);
    const on = await ready("a", (host) => (host.settings = { autoSave: "afterDelay" }));
    on.view.type("b");
    on.store.edited();
    expect(on.scheduled.length).toBe(1);
    on.scheduled[0]();
    await Promise.resolve();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(on.host.saves.map((save) => save.text)).toEqual(["b"]);
  });

  test("a conflicting save raises the banner; Keep My Changes writes over the disk", async () => {
    const { host, store, view } = await ready("a");
    view.type("mine");
    store.edited();
    host.text = "theirs";
    host.hash = "h:theirs";
    await store.save();
    expect(store.getState().conflict).toEqual({ hash: "h:theirs", text: "theirs", deleted: undefined });
    await store.keepMine();
    expect(host.text).toBe("mine");
    expect(store.getState().conflict).toBeNull();
  });

  test("a disk change reloads a clean file and raises the banner over edits", async () => {
    const clean = await ready("a");
    clean.host.diskWrite("b");
    expect(clean.view.body).toBe("b");
    expect(clean.view.loads).toBe(2);
    const dirty = await ready("a");
    dirty.view.type("mine");
    dirty.store.edited();
    dirty.host.diskWrite("theirs");
    expect(dirty.view.body).toBe("mine");
    expect(dirty.store.getState().conflict?.text).toBe("theirs");
    dirty.store.reloadFromDisk();
    expect(dirty.view.body).toBe("theirs");
  });

  test("a read-only file never saves", async () => {
    const { host, store, view } = await ready("a", (host) => (host.readOnly = true));
    expect(store.getState().readOnlyReason).toBe("outside");
    view.type("b");
    store.edited();
    await store.save();
    expect((await store.flush()).dirty).toBe(false);
    expect(host.saves).toEqual([]);
  });

  test("flush saves pending edits and reports what is left", async () => {
    const { host, store, view } = await ready("a");
    view.type("b");
    store.edited();
    expect(await store.flush()).toEqual({ dirty: false });
    expect(host.text).toBe("b");
  });

  test("a preference writes the editor.* key through the host and applies at once", async () => {
    const { host, store } = await ready("a");
    await store.setPreference("editor.minimap.enabled", true);
    expect(host.preferences).toEqual([{ key: "editor.minimap.enabled", value: true }]);
    expect(store.getState().look.settings).toEqual({ autoSave: "off", minimap: { enabled: true } });
  });

  test("the look stream replaces only the keys it sends", async () => {
    const { host, store } = await ready("a");
    host.look({ themeCSS: ".x{}" });
    expect(store.getState().look.themeCSS).toBe(".x{}");
    expect(store.getState().look.settings).toEqual({ autoSave: "off" });
    host.look({ screenReader: true });
    expect(store.getState().look.screenReader).toBe(true);
  });
});

describe("withSetting", () => {
  test("sets a nested key and expands a boolean shorthand", () => {
    expect(withSetting({ minimap: false, wordWrap: "on" }, "minimap.enabled", true)).toEqual({
      minimap: { enabled: true },
      wordWrap: "on",
    });
    expect(withSetting(undefined, "wordWrap", "off")).toEqual({ wordWrap: "off" });
  });
});
