// The App Store keeps its route, search, category and listing scroll across a discard:
// the hide saves them, and the restored document's store starts from them.
import { describe, expect, test } from "bun:test";
import { BridgePageClient, type ReplyHandler } from "../shared/pageClient";
import { openPageState } from "../shared/pageState";
import { FakePageDom, discardAndRestore, restoredClient } from "../shared/pageStateTesting";
import { parseRoute, routeHash } from "./model";
import { APPS_PAGE, AppsStore, restoredAppsInputs } from "./store";

const handler: ReplyHandler = { postMessage: async () => ({ t: "ok", id: 0, value: null }) };

/** A store on `dom` as main.tsx makes it: its route writes go to the page's fragment. */
function storeOn(dom: FakePageDom, client: BridgePageClient | null = null): AppsStore {
  return new AppsStore(client, dom.hash, { replaceRoute: dom.replaceRoute });
}

describe("App Store page state", () => {
  test("the tab the person picked, the search and the scroll come back after a discard", () => {
    const before = new FakePageDom("#/discover");
    before.scroller("installed", 4000).scrollTop = 640;
    const state = openPageState(new BridgePageClient(handler, { location: { hash: "#/discover" } }), APPS_PAGE, before);
    const store = storeOn(before);
    state.keep(() => store.pageInputs());
    store.setQuery("git");
    store.setCategory("Developer");
    store.setTab("installed");
    expect(before.hash).toBe("#/installed");

    const client = discardAndRestore(before, "#/discover");
    const after = new FakePageDom("#/discover");
    const installed = after.scroller("installed", 4000);
    openPageState(client, APPS_PAGE, after).keep(() => null);
    expect(after.hash).toBe("#/installed");
    expect(storeOn(after, client).getSnapshot()).toMatchObject({
      tab: "installed",
      query: "git",
      category: "Developer",
    });
    expect(installed.scrollTop).toBe(640);
  });

  test("the listing the person opened comes back, and going back clears it", () => {
    const before = new FakePageDom("#/discover?layout=split");
    openPageState(new BridgePageClient(handler, { location: { hash: before.hash } }), APPS_PAGE, before).keep(
      () => null,
    );
    const store = storeOn(before);
    void store.select("cmux.github-prs");
    expect(parseRoute(before.hash)).toMatchObject({ tab: "discover", layout: "split", app: "cmux.github-prs" });

    const client = discardAndRestore(before, "#/discover?layout=split");
    const after = new FakePageDom("#/discover?layout=split");
    openPageState(client, APPS_PAGE, after).keep(() => null);
    const restored = storeOn(after, client);
    expect(restored.getSnapshot()).toMatchObject({ layout: "split", selection: "cmux.github-prs" });
    void restored.select(undefined);
    expect(after.hash).toBe("#/discover?layout=split");
  });

  test("a route the host sets is shown but not written back", () => {
    const dom = new FakePageDom("#/discover");
    const store = storeOn(dom);
    store.applyRoute("#/installed?extra=1");
    expect(store.getSnapshot().tab).toBe("installed");
    expect(dom.replaced).toEqual([]);
  });

  test("the route the store writes reads back the same", () => {
    const route = { tab: "discover", layout: "list", card: "artwork", app: "a b" } as const;
    expect(parseRoute(routeHash(route))).toEqual(route);
    expect(routeHash({ tab: "installed", layout: "grid", card: "standard" })).toBe("#/installed");
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
