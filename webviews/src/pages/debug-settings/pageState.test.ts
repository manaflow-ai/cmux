// Debug Settings keeps its scroll across a discard; the app keeps its search and
// selection (DebugSettingsModel), so the page saves no inputs of its own.
import { describe, expect, test } from "bun:test";
import { BridgePageClient, type ReplyHandler } from "../shared/pageClient";
import { openPageState, restoredPageInputs } from "../shared/pageState";
import { FakePageDom, discardAndRestore } from "../shared/pageStateTesting";
import { DEBUG_SETTINGS_PAGE } from "./store";

const handler: ReplyHandler = { postMessage: async () => ({ t: "ok", id: 0, value: null }) };

describe("Debug Settings page state", () => {
  test("a hide, a discard and a restore give the next document the same scroll", () => {
    const before = new FakePageDom("");
    before.scroller("list", 8000).scrollTop = 2400;
    openPageState(new BridgePageClient(handler, {}), DEBUG_SETTINGS_PAGE, before).keep(() => null);

    const client = discardAndRestore(before);
    const after = new FakePageDom("");
    const list = after.scroller("list", 1000);
    openPageState(client, DEBUG_SETTINGS_PAGE, after).keep(() => null);
    expect(restoredPageInputs(client, DEBUG_SETTINGS_PAGE)).toBeUndefined();
    // The sections render after the app's first state: the scroll comes back when they do.
    expect(list.scrollTop).toBe(900);
    list.scrollHeight = 8000;
    after.layout();
    expect(list.scrollTop).toBe(2400);
  });
});
