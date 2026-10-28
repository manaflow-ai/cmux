// A page's route, scroll and unsent inputs survive a discard: saved when the page
// hides, given back to the next document before its first paint, as Chrome's PageState is.
import { describe, expect, test } from "bun:test";
import { BridgePageClient, type PageClient, type ReplyHandler } from "./pageClient";
import {
  DOCUMENT_SCROLL_KEY,
  PAGE_STATE_VERSION,
  SCROLL_RESTORE_ATTEMPTS,
  openPageState,
  restoredPageInputs,
  savedPageState,
  type SavedPageState,
} from "./pageState";
import { FakePageDom, discardAndRestore, restoredClient } from "./pageStateTesting";

const handler: ReplyHandler = { postMessage: async () => ({ t: "ok", id: 0, value: null }) };

function saved(overrides: Partial<SavedPageState> = {}): SavedPageState {
  return {
    v: PAGE_STATE_VERSION,
    page: "history",
    entryRoute: "#/",
    route: "#/",
    scroll: {},
    inputs: null,
    ...overrides,
  };
}

describe("page state save on hide", () => {
  test("the hide saves the route, the scroll above 0 and the inputs", () => {
    const dom = new FakePageDom("#/a");
    dom.scroller(DOCUMENT_SCROLL_KEY, 300).scrollTop = 0;
    dom.scroller("list", 1000).scrollTop = 420;
    const client = new BridgePageClient(handler, { location: { hash: "#/a" } });
    openPageState(client, "history", dom).keep(() => ({ text: "deploy" }));
    dom.hash = "#/b";
    dom.hide();
    expect(dom.lastSaved()).toEqual({
      v: PAGE_STATE_VERSION,
      page: "history",
      entryRoute: "#/a",
      route: "#/b",
      scroll: { list: 420 },
      inputs: { text: "deploy" },
    });
    expect(dom.storedState()).toBe(dom.posts.at(-1));
  });

  test("a claimed pooled document saves the claim's route as its entry", async () => {
    const dom = new FakePageDom("");
    const location = { hash: "", replace: (url: string) => void (location.hash = url) };
    const target: Record<string, unknown> = { __cmuxPageParked: true, location };
    const replies: unknown[] = [];
    const client = new BridgePageClient(
      {
        postMessage: async (body) => {
          replies.push(body);
          return { t: "ok", id: 0, value: null };
        },
      },
      target,
    );
    openPageState(client, "apps", dom).keep(() => null);
    client.receive({ t: "call", id: 1, op: "cmux.page.claim", params: { route: "#/installed" } });
    await Promise.resolve();
    dom.hash = "#/installed?app=x";
    dom.hide();
    expect(dom.lastSaved()).toMatchObject({ entryRoute: "#/installed", route: "#/installed?app=x" });
  });

  test("the stop function ends the save and the restore", () => {
    const dom = new FakePageDom("#/");
    const stop = openPageState(restoredClient(saved({ scroll: { list: 500 } }), "#/"), "history", dom).keep(() => null);
    expect(dom.observerCount()).toBe(2);
    stop();
    expect(dom.observerCount()).toBe(0);
    dom.hide();
    expect(dom.posts).toEqual([]);
  });
});

describe("page state restore", () => {
  test("the route the page had moved on to comes back when the host shows the same entry", () => {
    const dom = new FakePageDom("#/discover");
    const state = openPageState(
      restoredClient(saved({ entryRoute: "#/discover", route: "#/detail?app=x" })),
      "history",
      dom,
    );
    expect(state.saved?.route).toBe("#/detail?app=x");
    expect(dom.hash).toBe("#/detail?app=x");
    expect(dom.replaced).toEqual(["#/detail?app=x"]);
  });

  test("a host that sent the page somewhere else wins, and the old scroll stays off the new route", () => {
    const dom = new FakePageDom("#/installed");
    const list = dom.scroller("list", 2000);
    openPageState(
      restoredClient(saved({ entryRoute: "#/discover", route: "#/discover", scroll: { list: 700 } })),
      "history",
      dom,
    ).keep(() => null);
    dom.layout();
    expect(dom.hash).toBe("#/installed");
    expect(dom.replaced).toEqual([]);
    expect(list.scrollTop).toBe(0);
  });

  test("a page the host moved itself comes back at that route with its scroll", () => {
    // Shown at #/discover, then `open(route: "#/installed")` set the hash on the live document; the
    // restore loads the host's last route.
    const dom = new FakePageDom("#/installed");
    const list = dom.scroller("list", 2000);
    openPageState(
      restoredClient(saved({ entryRoute: "#/discover", route: "#/installed", scroll: { list: 700 } })),
      "history",
      dom,
    ).keep(() => null);
    expect(dom.replaced).toEqual([]);
    expect(list.scrollTop).toBe(700);
  });

  test("the scroll comes back in the layout that makes the list tall enough, then stops", () => {
    const dom = new FakePageDom("#/");
    const list = dom.scroller("list", 100);
    openPageState(restoredClient(saved({ scroll: { list: 600 } })), "history", dom).keep(() => null);
    expect(list.scrollTop).toBe(0);
    list.scrollHeight = 400;
    dom.layout();
    expect(list.scrollTop).toBe(300);
    list.scrollHeight = 2000;
    dom.layout();
    expect(list.scrollTop).toBe(600);
    expect(dom.observerCount()).toBe(0);
  });

  test("the person's first scroll ends the restore", () => {
    const dom = new FakePageDom("#/");
    const list = dom.scroller("list", 100);
    openPageState(restoredClient(saved({ scroll: { list: 600 } })), "history", dom).keep(() => null);
    dom.userInput();
    list.scrollHeight = 2000;
    dom.layout();
    expect(list.scrollTop).toBe(0);
    expect(dom.observerCount()).toBe(0);
  });

  test("a list that never grows tall enough stops after the bounded number of layouts", () => {
    const dom = new FakePageDom("#/");
    const list = dom.scroller("list", 300);
    openPageState(restoredClient(saved({ scroll: { list: 600 } })), "history", dom).keep(() => null);
    for (let index = 0; index < SCROLL_RESTORE_ATTEMPTS; index += 1) dom.layout();
    expect(list.scrollTop).toBe(200);
    expect(dom.observerCount()).toBe(0);
  });

  test("a scroller that mounts late takes its offset when it appears", () => {
    const dom = new FakePageDom("#/");
    openPageState(restoredClient(saved({ scroll: { list: 250 } })), "history", dom).keep(() => null);
    const list = dom.scroller("list", 1000);
    dom.layout();
    expect(list.scrollTop).toBe(250);
  });

  test("a hide before the list is tall enough saves the saved offset, and the restore goes on", () => {
    const dom = new FakePageDom("#/");
    const list = dom.scroller("list", 100);
    openPageState(restoredClient(saved({ scroll: { list: 600, other: 80 } })), "history", dom).keep(() => null);
    list.scrollHeight = 300;
    dom.layout();
    expect(list.scrollTop).toBe(200);
    dom.hide();
    expect(dom.lastSaved().scroll).toEqual({ list: 600, other: 80 });
    // The list lays out while the page is hidden: it takes its offset, ready for the reshow.
    list.scrollHeight = 2000;
    dom.layout();
    expect(list.scrollTop).toBe(600);
  });

  test("after the person scrolls, a hide saves where they are, not the old offset", () => {
    const dom = new FakePageDom("#/");
    const list = dom.scroller("list", 300);
    openPageState(restoredClient(saved({ scroll: { list: 600 } })), "history", dom).keep(() => null);
    dom.userInput();
    list.scrollTop = 50;
    dom.hide();
    expect(dom.lastSaved().scroll).toEqual({ list: 50 });
  });

  test("another page's state, another version and junk are not read", () => {
    expect(savedPageState(restoredClient(saved({ page: "apps" })), "history")).toBeNull();
    expect(savedPageState(restoredClient({ ...saved(), v: 2 }), "history")).toBeNull();
    expect(savedPageState(restoredClient("text"), "history")).toBeNull();
    expect(savedPageState(new BridgePageClient(handler, {}), "history")).toBeNull();
    expect(savedPageState(null, "history")).toBeNull();
    const mock: PageClient = {
      call: async () => null as never,
      subscribe: async () => () => {},
      handle: () => () => {},
    };
    expect(restoredPageInputs(mock, "history")).toBeUndefined();
  });

  test("bad scroll offsets are dropped", () => {
    const state = savedPageState(
      restoredClient(saved({ scroll: { a: -3, b: Number.NaN, c: "9", d: 40 } as unknown as Record<string, number> })),
      "history",
    );
    expect(state?.scroll).toEqual({ d: 40 });
  });

  test("a save, a discard and a restore round-trip the whole state", () => {
    const before = new FakePageDom("#/a");
    before.scroller("list", 3000).scrollTop = 1234;
    openPageState(new BridgePageClient(handler, { location: { hash: "#/a" } }), "history", before).keep(() => ({
      text: "x",
    }));
    before.hash = "#/a?sel=1";
    const client = discardAndRestore(before, "#/a");
    const after = new FakePageDom("#/a");
    const list = after.scroller("list", 3000);
    const state = openPageState(client, "history", after);
    state.keep(() => null);
    expect(after.hash).toBe("#/a?sel=1");
    expect(restoredPageInputs(client, "history")).toEqual({ text: "x" });
    expect(list.scrollTop).toBe(1234);
  });
});
