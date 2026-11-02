import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { NewTabHost } from "../NewTabPage";
import { EMPTY_OMNIBAR } from "../omnibar";
import {
  injectedNewTabContext,
  NEW_TAB_ADOPT_EVENT,
  NEW_TAB_PLACES_EVENT,
  useNewTabAdoption,
  useNewTabPlaces,
  withHandshakeNewTab,
} from "./adoption";

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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
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
