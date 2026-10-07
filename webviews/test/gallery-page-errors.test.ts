import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import type { HostOp } from "./latency/mock-host";
import { historyFixtureOps, keybindingsFixtureOps } from "../src/gallery/frame/historyKeybindings";
import history from "../src/pages/history/history.gallery";
import keys from "../src/pages/keybindings/keybindings.gallery";
import editor from "../src/pages/editor/editor.gallery";
import { HistoryStore } from "../src/pages/history/store";
import { KeybindingsStore } from "../src/pages/keybindings/store";
import { GALLERY_NOW } from "../src/gallery/clock";
function client(ops: Record<string, HostOp>): PageClient {
  return {
    call: async <R>(op: string, params: unknown) => (await ops[op]!(params ?? {}, {})) as R,
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}
test("history permission refusal keeps the timeline loaded until a mutation", async () => {
  const state = history.variants["permission-error"]!;
  const store = new HistoryStore(client(historyFixtureOps(state)));
  await store.start();
  expect(store.getSnapshot().entries.length).toBeGreaterThan(0);
  expect(store.getSnapshot().error).toBeUndefined();
  await store.remove(state.entries![0]!);
  expect(store.getSnapshot().error).toContain("cannot be changed");
});
for (const variant of ["unsupported", "not-found-error"]) {
  test(`keybindings ${variant} keeps bindings available before the refused action`, async () => {
    const state = keys.variants[variant]!;
    const c = client(keybindingsFixtureOps(state));
    const store = new KeybindingsStore(c);
    await store.start();
    expect(store.getSnapshot().rows.length).toBeGreaterThan(0);
    expect(store.getSnapshot().notice).toBeUndefined();
    const op = variant === "unsupported" ? "cmux.keybindings.set" : "cmux.keybindings.keymap.import";
    await expect(c.call(op, {})).rejects.toHaveProperty(
      "code",
      variant === "unsupported" ? "cmux.keybindings.unsupported" : "cmux.keybindings.keymap_failed",
    );
  });
}
test("history and editor fixture times are relative to the gallery clock", () => {
  expect(history.variants.normal!.entries![0]!.at_ms).toBe(GALLERY_NOW - 12 * 60_000);
  expect(editor.variants.empty!.recents![0]!.openedAt).toBe(GALLERY_NOW);
});
