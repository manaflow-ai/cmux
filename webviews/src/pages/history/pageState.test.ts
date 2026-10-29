// The History page keeps its search, filter, grouping, route and list scroll across a discard:
// the hide saves them, and the restored document's store starts from them.
import { describe, expect, test } from "bun:test";
import { BridgePageClient, type ReplyHandler } from "../shared/pageClient";
import { openPageState } from "../shared/pageState";
import { FakePageDom, discardAndRestore } from "../shared/pageStateTesting";
import { HISTORY_PAGE, HistoryStore } from "./store";

const handler: ReplyHandler = { postMessage: async () => ({ t: "ok", id: 0, value: null }) };

describe("History page state", () => {
  test("a hide, a discard and a restore give the next document the same query and scroll", () => {
    const before = new FakePageDom("#/");
    before.scroller("list", 5000).scrollTop = 900;
    const store = new HistoryStore(null);
    openPageState(new BridgePageClient(handler, { location: { hash: "#/" } }), HISTORY_PAGE, before).keep(() =>
      store.pageInputs(),
    );
    store.setText("deploy");
    store.setFilter("commands");
    store.setGrouping("workspace");

    const client = discardAndRestore(before);
    const after = new FakePageDom("#/");
    const list = after.scroller("list", 5000);
    openPageState(client, HISTORY_PAGE, after).keep(() => null);
    expect(new HistoryStore(client).getSnapshot()).toMatchObject({
      text: "deploy",
      filter: "commands",
      grouping: "workspace",
    });
    expect(list.scrollTop).toBe(900);
  });
});
