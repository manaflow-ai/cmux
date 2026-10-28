// The Keyboard Shortcuts page keeps its search, key filter, conflicts switch and list scroll across a
// discard: the hide saves them, and the restored document's store starts from them.
import { describe, expect, test } from "bun:test";
import { BridgePageClient, type ReplyHandler } from "../shared/pageClient";
import { openPageState } from "../shared/pageState";
import { FakePageDom, discardAndRestore } from "../shared/pageStateTesting";
import { KEYBINDINGS_PAGE, KeybindingsStore, restoredKeybindingsInputs } from "./store";

const handler: ReplyHandler = { postMessage: async () => ({ t: "ok", id: 0, value: null }) };

describe("Keyboard Shortcuts page state", () => {
  test("a hide, a discard and a restore give the next document the same query and scroll", () => {
    const before = new FakePageDom("");
    before.scroller("list", 6000).scrollTop = 1500;
    const store = new KeybindingsStore(null);
    openPageState(new BridgePageClient(handler, {}), KEYBINDINGS_PAGE, before).keep(() => store.pageInputs());
    store.showSameKeys({ key: "cmd+k" } as Parameters<KeybindingsStore["showSameKeys"]>[0]);
    store.setConflictsOnly(true);

    const client = discardAndRestore(before);
    const after = new FakePageDom("");
    const list = after.scroller("list", 6000);
    openPageState(client, KEYBINDINGS_PAGE, after).keep(() => null);
    expect(new KeybindingsStore(client).getSnapshot()).toMatchObject({
      text: "cmd+k",
      keyFilter: { key: "cmd+k", exact: true },
      conflictsOnly: true,
    });
    expect(list.scrollTop).toBe(1500);
  });

  test("only valid saved fields are taken", () => {
    expect(restoredKeybindingsInputs({ text: 1, keyFilter: { key: "a" }, conflictsOnly: "yes" })).toEqual({});
    expect(restoredKeybindingsInputs({ text: "a", conflictsOnly: false })).toEqual({ text: "a", conflictsOnly: false });
    expect(restoredKeybindingsInputs(null)).toEqual({});
  });
});
