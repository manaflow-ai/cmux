import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { newTabHost, type NewTabHost } from "../newTabModel";
import { EMPTY_OMNIBAR } from "../omnibar";
import {
  injectedNewTabContext,
  NEW_TAB_ADOPT_EVENT,
  NEW_TAB_PLACES_EVENT,
  useEarlyNewTabContext,
  useLostSharedPart,
  useNewTabAdoption,
  useNewTabPlaces,
  withHandshakeNewTab,
} from "./adoption";
import { lacksSharedPart } from "./sharedPart";
import { settleReact } from "../../../../test/support/domTeardown";

// Cmd-N's first page shows without the Commands palette's actions and lists them on the frame after
// (NewTabPage.fillPaletteActions). On a cold WebKit page the host injects the context (empty list)
// as the document commits, and the actions' places event can come before React listens for it.
// The handshake, read after they were listed, still brings them in.

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

const actions = [
  { id: "newWindow", title: "New Window", detail: "Windows", keywords: ["window"] },
  { id: "toggleSidebar", title: "Toggle Sidebar", detail: "View", keywords: [] },
];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "CustomEvent", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    CustomEvent: dom.window.CustomEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

/// The page's New Tab state as App holds it: the injected context first, places events after.
function mount() {
  const view: { host?: NewTabHost; set?: (apply: (host: NewTabHost | undefined) => NewTabHost | undefined) => void } =
    {};
  function Probe() {
    const [host, setHost] = useState<NewTabHost | undefined>(injectedNewTabContext);
    useNewTabPlaces(setHost);
    view.host = host;
    view.set = setHost;
    return null;
  }
  act(() => root!.render(<Probe />));
  return view;
}

const places = (detail: unknown) => new dom!.window.CustomEvent(NEW_TAB_PLACES_EVENT, { detail });

test("a refused early context does not identify an unknown page as a chat", async () => {
  let known = false;
  const read = () => Promise.reject(new Error("context unavailable"));
  const take = () => {
    throw new Error("a refused read has no context");
  };
  const settle = () => {
    known = true;
  };
  function Probe() {
    useEarlyNewTabContext(read, take, settle);
    return null;
  }
  await act(async () => root!.render(<Probe />));
  // App keeps the surface hidden until ready identifies it or reports the host error.
  expect(known).toBe(false);
});

test.each([false, true])("an answered context identifies the page (New Tab: %s)", async (isNewTab) => {
  let known = false;
  let context: NewTabHost | undefined;
  const read = () => Promise.resolve(isNewTab ? { newTab: true } : {});
  const take = (host: NewTabHost) => {
    context = host;
  };
  const settle = () => {
    known = true;
  };
  function Probe() {
    useEarlyNewTabContext(read, take, settle);
    return null;
  }
  await act(async () => root!.render(<Probe />));
  expect(known).toBe(true);
  expect(context !== undefined).toBe(isNewTab);
});

test("a cold page whose actions event came before its listener lists them from the handshake", () => {
  (dom!.window as { __cmuxNewTabContext?: unknown }).__cmuxNewTabContext = { omnibar: { ...EMPTY_OMNIBAR } };
  // The two-frame fill runs before the bundle mounted: nothing listens, the event is lost.
  dom!.window.dispatchEvent(places({ ...EMPTY_OMNIBAR, actions }));
  const view = mount();
  expect(view.host?.omnibar?.actions ?? []).toEqual([]);

  // The handshake (AgentPaneHandshakeReply reads the model after the fill) carries the actions.
  act(() =>
    view.set!((current) =>
      withHandshakeNewTab(current, { newTab: { omnibar: { ...EMPTY_OMNIBAR, actions } }, cwd: "/work/app" }),
    ),
  );
  expect(view.host?.omnibar?.actions).toEqual(actions);
  expect(view.host?.cwd).toBe("/work/app");
});

test("the handshake keeps actions and a folder the page already has", () => {
  const host = { hotkeys: {}, initialKind: "agent", layout: "b", cwd: "/mine", omnibar: { ...EMPTY_OMNIBAR, actions } };
  const later = withHandshakeNewTab(host as NewTabHost, {
    newTab: { omnibar: { ...EMPTY_OMNIBAR, actions: [{ id: "other", title: "Other", keywords: [] }] } },
    cwd: "/theirs",
  });
  expect(later).toBe(host as NewTabHost);
  expect(withHandshakeNewTab(undefined, { newTab: { omnibar: { actions } } })).toBeUndefined();
});

test("an actions event after the listener still fills the bar in place", () => {
  (dom!.window as { __cmuxNewTabContext?: unknown }).__cmuxNewTabContext = { omnibar: { ...EMPTY_OMNIBAR } };
  const view = mount();
  act(() => {
    dom!.window.dispatchEvent(places({ ...EMPTY_OMNIBAR, actions }));
  });
  expect(view.host?.omnibar?.actions).toEqual(actions);
});

// SHORTCUT FRAMES F2 (120 Hz video, feat 1cb7548, 2026-11-02): Cmd-T's first frame showed the spare's
// screen, then the adopted page remounted (the folder chip changed, the sign-in line went and came back,
// the "Trust <folder>?" card came): the content moved twice after the key. A spare already prepared
// with the tab's context gets an adopt event that differs only in its input token and the bar's
// places: the screen must stay mounted (the first frame is the final one) and take the token in place.
function mountAdoption() {
  const view: { host?: NewTabHost; generation?: number } = {};
  function Probe() {
    const [host, setHost] = useState<NewTabHost | undefined>(undefined);
    const current = { host };
    const generation = useNewTabAdoption(setHost, () => current.host);
    view.host = host;
    view.generation = generation;
    return null;
  }
  act(() => root!.render(<Probe />));
  return view;
}

const adopt = (detail: unknown) => new dom!.window.CustomEvent(NEW_TAB_ADOPT_EVENT, { detail });
const prepared = {
  hotkeys: {},
  kind: "agent",
  layout: "b",
  cwd: "/tmp",
  home: "/Users/me",
  omnibar: { ...EMPTY_OMNIBAR },
};

test("an adoption with the context the spare already shows keeps its screen mounted", () => {
  const view = mountAdoption();
  act(() => {
    dom!.window.dispatchEvent(adopt(prepared));
  });
  expect(view.generation).toBe(1);
  expect(view.host?.cwd).toBe("/tmp");
  const tabs = [{ id: "t1", title: "zsh", kind: "terminal", workspace: "w" }];
  act(() => {
    dom!.window.dispatchEvent(adopt({ ...prepared, inputToken: "key-1", omnibar: { ...EMPTY_OMNIBAR, tabs } }));
  });
  expect(view.generation).toBe(1);
  expect(view.host?.inputToken).toBe("key-1");
  expect(view.host?.cwd).toBe("/tmp");
});

test("an adoption with another folder still remounts the screen", () => {
  const view = mountAdoption();
  act(() => {
    dom!.window.dispatchEvent(adopt(prepared));
  });
  act(() => {
    dom!.window.dispatchEvent(adopt({ ...prepared, cwd: "/work/app", inputToken: "key-2" }));
  });
  expect(view.generation).toBe(2);
  expect(view.host?.cwd).toBe("/work/app");
});

test("the same screen with its keys in another order keeps its screen mounted", () => {
  const view = mountAdoption();
  act(() => {
    dom!.window.dispatchEvent(adopt({ ...prepared, headlineOff: true }));
  });
  const { cwd, ...rest } = prepared;
  act(() => {
    dom!.window.dispatchEvent(adopt({ headlineOff: true, ...rest, cwd, inputToken: "key-3" }));
  });
  expect(view.generation).toBe(1);
  expect(view.host?.inputToken).toBe("key-3");
});

// SHORTCUT LATENCY (2026-11-02): the host's places refresh sends only the open tabs and workspaces
// (AgentPaneView.refreshNewTabPlaces); the page keeps the rest of its bar.
test("a places event with only tabs and workspaces keeps the bar's actions, recent pages and commands", () => {
  const history = [{ url: "https://example.com/", title: "Example" }];
  (dom!.window as { __cmuxNewTabContext?: unknown }).__cmuxNewTabContext = {
    omnibar: { ...EMPTY_OMNIBAR, actions, history, commands: ["make"], folders: ["/work/app"] },
  };
  const view = mount();
  act(() => {
    dom!.window.dispatchEvent(
      places({
        tabs: [{ id: "tab_1", kind: "terminal", title: "zsh", workspace: "Work" }],
        workspaces: [{ id: "ws_2", name: "Other" }],
      }),
    );
  });
  expect(view.host?.omnibar?.tabs.map((tab) => tab.id)).toEqual(["tab_1"]);
  expect(view.host?.omnibar?.workspaces.map((workspace) => workspace.id)).toEqual(["ws_2"]);
  expect(view.host?.omnibar?.actions).toEqual(actions);
  expect(view.host?.omnibar?.history.map((page) => page.url)).toEqual(["https://example.com/"]);
  expect(view.host?.omnibar?.commands).toEqual(["make"]);
  expect(view.host?.omnibar?.folders).toEqual(["/work/app"]);
});

// The host sends the context in two parts (sharedPart.ts): the page's own part at each send, and the
// large shared part one time for a document, as JSON text. The own part names the shared part's generation.
const sharedPart = (commands: string[]) => ({
  hotkeys: { agent: "⌘J" },
  projects: ["/work/app"],
  layout: "a",
  omnibar: { ...EMPTY_OMNIBAR, workspaces: [{ id: "ws_1", name: "Work" }], folders: ["/work/app"], actions, commands },
});
const ownPart = (inputToken: string, tabs: number, sharedGeneration = 1) => ({
  kind: "agent",
  cwd: "/work/app",
  inputToken,
  sharedGeneration,
  omnibar: {
    tabs: Array.from({ length: tabs }, (_, index) => ({ id: `tab_${index}`, kind: "agent", title: `Tab ${index}` })),
  },
});

test("a context in two parts is joined: each page's own part with the shared text that came one time", () => {
  const first = newTabHost({ newTab: { ...ownPart("key-1", 1), shared: JSON.stringify(sharedPart(["ls"])) } });
  expect(first?.inputToken).toBe("key-1");
  expect(first?.omnibar?.tabs.map((tab) => tab.id)).toEqual(["tab_0"]);
  expect(first?.omnibar?.actions).toEqual(actions);
  expect(first?.omnibar?.workspaces.map((workspace) => workspace.id)).toEqual(["ws_1"]);
  expect(first?.hotkeys).toEqual({ agent: "⌘J" });
  expect(first?.layout).toBe("a");
  expect(first?.projects).toEqual(["/work/app"]);

  // The next send of this generation carries the own part only: the document's kept shared part joins it.
  expect(lacksSharedPart(ownPart("key-2", 2))).toBe(false);
  const second = newTabHost({ newTab: ownPart("key-2", 2) });
  expect(second?.inputToken).toBe("key-2");
  expect(second?.omnibar?.tabs.map((tab) => tab.id)).toEqual(["tab_0", "tab_1"]);
  expect(second?.omnibar?.actions).toEqual(actions);
  expect(second?.omnibar?.commands).toEqual(["ls"]);
  expect(second?.hotkeys).toEqual({ agent: "⌘J" });

  // A changed shared part comes as a new generation with its text, and replaces the kept one.
  const changed = { ...ownPart("key-3", 2, 2), shared: JSON.stringify(sharedPart(["ls", "make"])) };
  expect(newTabHost({ newTab: changed })?.omnibar?.commands).toEqual(["ls", "make"]);
  expect(newTabHost({ newTab: ownPart("key-4", 2, 2) })?.omnibar?.commands).toEqual(["ls", "make"]);
});

test("a page that gets its own part while its document keeps no shared part asks for its context again", async () => {
  const asked: string[] = [];
  const callNative = (method: string) => {
    asked.push(method);
    // `newTab.context`'s answer always carries the shared text (AgentPaneModel.respond).
    return Promise.resolve({ newTab: { ...ownPart("key-1", 1), shared: JSON.stringify(sharedPart(["ls"])) } });
  };
  const view: { host?: NewTabHost; check?: (newTab: unknown) => void } = {};
  function Probe() {
    const [host, setHost] = useState<NewTabHost | undefined>(undefined);
    useNewTabAdoption(setHost);
    view.check = useLostSharedPart(callNative, setHost);
    view.host = host;
    return null;
  }
  act(() => root!.render(<Probe />));

  // The host's mark said that this document has generation 1; it has none (a lost state).
  expect(lacksSharedPart(ownPart("key-1", 1))).toBe(true);
  await act(async () => {
    dom!.window.dispatchEvent(adopt(ownPart("key-1", 1)));
    await Promise.resolve();
  });
  expect(asked).toEqual(["newTab.context"]);
  expect(view.host?.inputToken).toBe("key-1");
  expect(view.host?.omnibar?.tabs.map((tab) => tab.id)).toEqual(["tab_0"]);
  expect(view.host?.omnibar?.actions).toEqual(actions);
  expect(view.host?.hotkeys).toEqual({ agent: "⌘J" });

  // The document has the shared part now: an own part of that generation asks nothing, by an event or a reply.
  await act(async () => {
    dom!.window.dispatchEvent(adopt(ownPart("key-2", 2)));
    view.check!(ownPart("key-2", 2));
    await Promise.resolve();
  });
  expect(asked).toEqual(["newTab.context"]);
  expect(view.host?.inputToken).toBe("key-2");
  expect(view.host?.omnibar?.actions).toEqual(actions);
  // A context in the whole form (an older host) asks nothing.
  act(() => view.check!(prepared));
  expect(asked).toEqual(["newTab.context"]);
});
