// The App Store keeps its route, search, category and listing scroll across a discard
// (p13-webui-082): the hide saves them, and the restored document's store starts from them.
import { describe, expect, test } from "bun:test";
import { BridgePageClient, type ReplyHandler } from "../shared/pageClient";
import { openPageState } from "../shared/pageState";
import { FakePageDom, discardAndRestore, restoredClient } from "../shared/pageStateTesting";
import { APPS_PAGE, AppsStore, restoredAppsInputs } from "./store";

const handler: ReplyHandler = { postMessage: async () => ({ t: "ok", id: 0, value: null }) };

describe("App Store page state", () => {
  test("a hide, a discard and a restore give the next document the same route, inputs and scroll", () => {
    const before = new FakePageDom("#/discover");
    before.scroller("listing", 4000).scrollTop = 640;
    const store = new AppsStore(null, before.hash);
    openPageState(new BridgePageClient(handler, { location: { hash: "#/discover" } }), APPS_PAGE, before).keep(() =>
      store.pageInputs(),
    );
    store.setQuery("git");
    store.setCategory("Developer");
    // The page moved on by itself (its tab bar), after the host showed it at #/discover.
    before.hash = "#/installed";

    const client = discardAndRestore(before, "#/discover");
    const after = new FakePageDom("#/discover");
    const listing = after.scroller("listing", 4000);
    openPageState(client, APPS_PAGE, after).keep(() => null);
    expect(after.hash).toBe("#/installed");
    const restored = new AppsStore(client, after.hash).getSnapshot();
    expect(restored).toMatchObject({ tab: "installed", query: "git", category: "Developer" });
    expect(listing.scrollTop).toBe(640);
  });

  test("a document that was not discarded starts with no search", () => {
    expect(new AppsStore(restoredClient(null)).getSnapshot()).toMatchObject({ query: "" });
    expect(new AppsStore(restoredClient(null)).getSnapshot().category).toBeUndefined();
  });

  test("only valid saved fields are taken", () => {
    expect(restoredAppsInputs({ query: 3, category: "" })).toEqual({});
    expect(restoredAppsInputs({ query: "a", category: "Games" })).toEqual({ query: "a", category: "Games" });
    expect(restoredAppsInputs("query")).toEqual({});
  });
});
