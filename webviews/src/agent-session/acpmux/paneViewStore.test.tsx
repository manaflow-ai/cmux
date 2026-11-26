// Per-view host state in a shared pane document (paneViewStore.ts, goal memory-per-chat): a chat's
// header, row, notices and cards are its view's, so two chats in one document never draw each
// other's; the page's own view (null) is today's one chat a page, unchanged.
import { afterEach, expect, test } from "bun:test";
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { PageClient } from "../../pages/shared/pageClient";
import { PaneViewContext, viewStore } from "./paneViewStore";
import { paneNotices, setPaneNotices, usePaneNotices } from "./paneNoticeStore";
import { headerState, resetHeaderStateForTests } from "./header/headerState";
import { currentToolCards } from "./toolCards/toolCardStore";
import { floatingState } from "./floatingState";
import {
  currentComputerUsePreview,
  closeComputerUsePreview,
  setComputerUsePreview,
} from "./computerUse/computerUsePreview";
import { applyHostEvent, HOST_EVENTS, startHostEvents, VIEW_EVENT_KINDS, type HostEvent } from "./pageHost";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  setPaneNotices([]);
  setPaneNotices([], "a");
  setPaneNotices([], "b");
  resetHeaderStateForTests();
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("each view keeps its own value; the page's null view is the default", () => {
  const store = viewStore(0);
  const woke: string[] = [];
  store.subscribe(() => woke.push("page"));
  store.subscribe(() => woke.push("a"), "a");
  store.set(1, "a");
  expect(store.get("a")).toBe(1);
  expect(store.get()).toBe(0);
  expect(store.get("b")).toBe(0);
  store.set(2);
  expect(woke).toEqual(["a", "page"]);
  // The same value again wakes nobody.
  store.set(2);
  expect(woke).toEqual(["a", "page"]);
  store.drop("a");
  expect(store.get("a")).toBe(0);
  expect(woke).toEqual(["a", "page", "a"]);
  expect(store.views()).toEqual([null]);
});

test("a component reads the view its context names", async () => {
  const container = installDom();
  const Notices = ({ label }: { label: string }) => {
    const notices = usePaneNotices();
    return createElement("p", { "data-label": label }, notices.map((notice) => notice.title).join(","));
  };
  root = createRoot(container);
  await act(async () =>
    root!.render(
      createElement(
        "div",
        null,
        createElement(Notices, { label: "page" }),
        createElement(PaneViewContext.Provider, { value: "a" }, createElement(Notices, { label: "a" })),
        createElement(PaneViewContext.Provider, { value: "b" }, createElement(Notices, { label: "b" })),
      ),
    ),
  );
  await act(async () => setPaneNotices([{ id: "x", title: "For a" }], "a"));
  await act(async () => setPaneNotices([{ id: "y", title: "For b" }], "b"));
  const text = (label: string) => container.querySelector(`[data-label=${label}]`)!.textContent;
  expect(text("a")).toBe("For a");
  expect(text("b")).toBe("For b");
  expect(text("page")).toBe("");
  expect(paneNotices()).toEqual([]);
});

test("a per-chat host event lands in the view whose subscription brought it", () => {
  installDom();
  applyHostEvent({ kind: "headerState", value: { pinned: true, version: 1 } }, "a");
  applyHostEvent({ kind: "toolCards", value: [{ id: "c", state: "ask", text: "Move?" }] }, "a");
  applyHostEvent({ kind: "floatingState", value: { collapsed: true } }, "b");
  expect(headerState("a").pinned).toBe(true);
  expect(headerState("b").pinned).toBe(false);
  expect(headerState().pinned).toBe(false);
  expect(currentToolCards("a").map((card) => card.id)).toEqual(["c"]);
  expect(currentToolCards()).toEqual([]);
  expect(floatingState("b").collapsed).toBe(true);
  expect(floatingState("a").collapsed).toBe(false);
  // The page's own subscription (no view) is today's: the page's values.
  applyHostEvent({ kind: "headerState", value: { pinned: true, version: 1 } });
  expect(headerState().pinned).toBe(true);
  for (const kind of ["headerState", "tabRow", "floatingState", "paneNotices", "toolCards", "computerUsePreview"])
    expect(VIEW_EVENT_KINDS.has(kind)).toBe(true);
  expect(VIEW_EVENT_KINDS.has("theme")).toBe(false);
});

test("closing a computer use card in one view leaves another view's card", () => {
  const card = (session: string) => ({ session, app: "Notes", frame: "data:image/png;base64,AA==" });
  setComputerUsePreview(card("s1"), "a");
  setComputerUsePreview(card("s1"), "b");
  closeComputerUsePreview("s1", "a");
  expect(currentComputerUsePreview("a")).toBeNull();
  expect(currentComputerUsePreview("b")?.session).toBe("s1");
  setComputerUsePreview(null, "a");
  setComputerUsePreview(null, "b");
});

test("each view subscribes to host events once, with its view filter", async () => {
  installDom();
  const subs: { stream: string; filter?: Record<string, unknown>; onEvent: (event: HostEvent) => void }[] = [];
  const page: PageClient = {
    call: async <R,>() => undefined as R,
    subscribe: async (stream, onEvent, filter) => {
      subs.push({ stream, filter, onEvent: onEvent as (event: HostEvent) => void });
      return () => {};
    },
    handle: () => () => {},
  };
  await Promise.all([startHostEvents(page), startHostEvents(page, "a"), startHostEvents(page, "a")]);
  expect(subs.map((sub) => [sub.stream, sub.filter])).toEqual([
    [HOST_EVENTS, undefined],
    [HOST_EVENTS, { view: "a" }],
  ]);
  subs[1]!.onEvent({ kind: "paneNotices", value: [{ id: "n", title: "Only a" }] });
  expect(paneNotices("a").map((notice) => notice.title)).toEqual(["Only a"]);
  expect(paneNotices()).toEqual([]);
});
