import { describe, expect, test } from "bun:test";
import { identity } from "./model";
import { MockKeybindingsProvider, sampleLayers } from "./mockProvider";
import { KeybindingsStore } from "./store";
import { KeybindingOps, type Binding } from "./types";

/** Lets queued promise callbacks run. */
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

async function started() {
  const provider = new MockKeybindingsProvider(sampleLayers());
  let keys = 0;
  const store = new KeybindingsStore(provider, { newKey: () => `k${++keys}` });
  const unsubscribe = store.subscribe(() => undefined);
  await store.start();
  await settle();
  return { provider, store, unsubscribe };
}

const row = (store: KeybindingsStore, command: string, source?: Binding["source"]) =>
  store.getSnapshot().bindings.find((b) => b.command === command && (!source || b.source === source) && !b.removed)!;
const writes = (provider: MockKeybindingsProvider, op: string) =>
  provider.calls.filter((call) => call.op === op).map((call) => call.params);

describe("KeybindingsStore", () => {
  test("loads the table sorted by title, then key, and subscribes to changes", async () => {
    const { provider, store } = await started();
    const snap = store.getSnapshot();
    expect(snap.connection).toBe("connected");
    expect(snap.loading).toBe(false);
    expect(provider.calls[0]).toEqual({ op: KeybindingOps.list, params: {} });
    expect(provider.subscriberCount).toBe(1);
    const titles = snap.bindings.map((b) => b.title);
    expect(titles).toEqual([...titles].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" })));
    expect(snap.rows).toHaveLength(snap.bindings.length);
    expect([...snap.resettable].sort()).toEqual(["history.open", "split.down"]);
  });

  test("the last unsubscribe stops the change subscription", async () => {
    const { provider, unsubscribe } = await started();
    unsubscribe();
    expect(provider.subscriberCount).toBe(0);
  });

  test("a change event re-lists", async () => {
    const { provider, store } = await started();
    provider.layers.user.push({ command: "tab.new", key: "cmd+shift+t", when: null });
    const before = provider.calls.length;
    provider.notifyChanged();
    await settle();
    expect(provider.calls.length).toBe(before + 1);
    expect(store.getSnapshot().bindings.some((b) => b.key === "cmd+shift+t")).toBe(true);
  });

  test("search, conflicts only and the same-keys filter", async () => {
    const { store } = await started();
    store.setText("split");
    expect(store.getSnapshot().rows.map((b) => b.command)).toEqual(["split.down", "split.down", "split.right"]);
    store.setText("");
    store.setConflictsOnly(true);
    expect(
      store
        .getSnapshot()
        .rows.map((b) => b.command)
        .sort(),
    ).toEqual(["history.open", "palette.open"]);
    store.setConflictsOnly(false);
    store.showSameKeys(row(store, "palette.open"));
    const snap = store.getSnapshot();
    expect(snap.text).toBe("cmd+shift+p");
    expect(snap.rows.map((b) => b.command).sort()).toEqual(["history.open", "palette.open"]);
    store.resetQuery();
    expect(store.getSnapshot()).toMatchObject({ text: "", keyFilter: undefined, conflictsOnly: false });
    expect(store.getSnapshot().rows).toHaveLength(store.getSnapshot().bindings.length);
  });

  test("a new `when` sets a user entry that replaces the old one", async () => {
    const { provider, store } = await started();
    const tab = row(store, "tab.new");
    store.editWhen(tab);
    expect(store.getSnapshot().editing).toBe(identity(tab));
    await store.commitWhen(tab, " surface.kind == 'terminal' ");
    expect(writes(provider, KeybindingOps.set)).toEqual([
      {
        command: "tab.new",
        key: "cmd+t",
        when: "surface.kind == 'terminal'",
        replaces: { key: "cmd+t", when: null },
        idempotency_key: "k1",
      },
    ]);
    const snap = store.getSnapshot();
    expect(snap.editing).toBeUndefined();
    const made = row(store, "tab.new", "user");
    expect(made.when).toBe("surface.kind == 'terminal'");
    expect(snap.selection).toBe(identity(made));
    expect(snap.bindings.some((b) => b.command === "tab.new" && b.removed)).toBe(true);
  });

  test("an unchanged `when` sends nothing", async () => {
    const { provider, store } = await started();
    const tab = row(store, "tab.new");
    store.editWhen(tab);
    await store.commitWhen(tab, "  ");
    expect(writes(provider, KeybindingOps.set)).toEqual([]);
    expect(store.getSnapshot().editing).toBeUndefined();
  });

  test("remove and reset send the entry and command with idempotency keys", async () => {
    const { provider, store } = await started();
    await store.remove(row(store, "split.down", "user"));
    expect(writes(provider, KeybindingOps.remove)).toEqual([
      { command: "split.down", key: "cmd+k cmd+d", when: null, idempotency_key: "k1" },
    ]);
    expect(store.getSnapshot().bindings.some((b) => b.key === "cmd+k cmd+d")).toBe(false);
    await store.reset(store.getSnapshot().bindings.find((b) => b.command === "split.down")!);
    expect(writes(provider, KeybindingOps.reset)).toEqual([{ command: "split.down", idempotency_key: "k2" }]);
    const split = store.getSnapshot().bindings.filter((b) => b.command === "split.down");
    expect(split.map((b) => [b.key, b.source, b.removed ?? false])).toEqual([["cmd+shift+d", "default", false]]);
    expect(store.getSnapshot().resettable.has("split.down")).toBe(false);
  });

  test("an unsupported write shows the notice and keeps the row", async () => {
    const { provider, store } = await started();
    provider.unsupported = true;
    const before = store.getSnapshot().bindings;
    const tab = row(store, "tab.new");
    await store.remove(tab);
    expect(store.getSnapshot().notice).toEqual({ kind: "unsupported" });
    expect(store.getSnapshot().bindings).toBe(before);
    await store.commitWhen(tab, "x");
    expect(store.getSnapshot().notice).toEqual({ kind: "unsupported" });
    provider.unsupported = false;
    await store.remove(tab);
    expect(store.getSnapshot().notice).toBeUndefined();
  });

  test("record keys fills the search and filters by the recorded prefix", async () => {
    const { provider, store } = await started();
    await store.toggleSearchRecording();
    expect(provider.recording).toBe(true);
    expect(store.getSnapshot().recording).toEqual({ target: "search" });
    provider.press("cmd+k");
    expect(store.getSnapshot()).toMatchObject({ text: "cmd+k", keyFilter: { key: "cmd+k", exact: false } });
    expect(
      store
        .getSnapshot()
        .rows.map((b) => b.command)
        .sort(),
    ).toEqual(["keybindings.open", "split.down"]);
    provider.press("cmd+s");
    expect(store.getSnapshot().rows.map((b) => b.command)).toEqual(["keybindings.open"]);
    provider.cancel();
    expect(store.getSnapshot().recording).toBeUndefined();
    expect(store.getSnapshot().text).toBe("cmd+k cmd+s");
    await settle();
    expect(writes(provider, KeybindingOps.recordStart)).toHaveLength(1);
    expect(writes(provider, KeybindingOps.recordStop)).toHaveLength(1);
    // Typing clears the key filter.
    store.setText("tab");
    expect(store.getSnapshot().keyFilter).toBeUndefined();
  });

  test("the toggle stops a running search recording", async () => {
    const { provider, store } = await started();
    await store.toggleSearchRecording();
    await store.toggleSearchRecording();
    expect(store.getSnapshot().recording).toBeUndefined();
    await settle();
    expect(provider.recording).toBe(false);
  });

  test("change keybinding records new keys and replaces the old entry", async () => {
    const { provider, store } = await started();
    const select = row(store, "tab.select");
    await store.changeKeybinding(select);
    expect(store.getSnapshot().recording).toMatchObject({ target: "row", row: identity(select), display: "" });
    provider.press("ctrl+k");
    expect(store.getSnapshot().recording).toMatchObject({ display: "⌃K" });
    provider.press("1");
    provider.finish();
    await settle();
    expect(store.getSnapshot().recording).toBeUndefined();
    expect(writes(provider, KeybindingOps.set)).toEqual([
      {
        command: "tab.select",
        key: "ctrl+k 1",
        when: null,
        args: { index: 1 },
        replaces: { key: "cmd+1", when: null },
        idempotency_key: "k1",
      },
    ]);
    const made = row(store, "tab.select", "user");
    expect(made.key).toBe("ctrl+k 1");
    expect(store.getSnapshot().selection).toBe(identity(made));
  });

  test("a cancelled change sends nothing", async () => {
    const { provider, store } = await started();
    await store.changeKeybinding(row(store, "tab.new"));
    provider.press("cmd+j");
    provider.cancel();
    await settle();
    expect(store.getSnapshot().recording).toBeUndefined();
    expect(writes(provider, KeybindingOps.set)).toEqual([]);
  });

  test("the fourth stroke ends a change", async () => {
    const { provider, store } = await started();
    await store.changeKeybinding(row(store, "tab.new"));
    for (const stroke of ["cmd+k", "a", "b", "c"]) provider.press(stroke);
    await settle();
    expect(writes(provider, KeybindingOps.set)).toMatchObject([{ key: "cmd+k a b c" }]);
  });

  test("a lost host shows disconnected; a connection event re-lists", async () => {
    const { provider, store } = await started();
    provider.page.setConnected(false);
    expect(store.getSnapshot().connection).toBe("disconnected");
    provider.page.setConnected(true);
    await settle();
    expect(store.getSnapshot().connection).toBe("connected");
    provider.offline = true;
    await store.reload();
    expect(store.getSnapshot().connection).toBe("disconnected");
  });

  test("no client: disconnected and nothing is sent", async () => {
    const store = new KeybindingsStore(null);
    store.subscribe(() => undefined);
    await store.start();
    expect(store.getSnapshot()).toMatchObject({ connection: "disconnected", loading: false });
  });
});

describe("keymap files", () => {
  test("export and import call the host and an import re-lists", async () => {
    const { provider, store } = await started();
    await store.exportKeymap();
    expect(writes(provider, KeybindingOps.keymapExport)).toEqual([{}]);
    const lists = provider.calls.filter((call) => call.op === KeybindingOps.list).length;
    await store.importKeymap();
    expect(writes(provider, KeybindingOps.keymapImport)).toEqual([{}]);
    expect(provider.calls.filter((call) => call.op === KeybindingOps.list).length).toBe(lists + 1);
  });

  test("a failed import shows the notice and keeps the rows", async () => {
    const { provider, store } = await started();
    const before = store.getSnapshot().bindings;
    provider.keymapFails = true;
    await store.importKeymap();
    expect(store.getSnapshot().notice).toBeDefined();
    expect(store.getSnapshot().bindings).toEqual(before);
  });
});
