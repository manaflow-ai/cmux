// l10n-allow-file: test fixtures.
// The Messages list's rows render only when what they draw changed. The page builds the list model
// again on every change and on its minute clock (every item a new object), so a row that keeps its
// text, its selection and its place renders 0 times: one conversation's new message redraws that row,
// a selection redraws the rows whose selected state or hairline flipped, a scroll step mounts only the
// rows coming into view. Counted from React's commits (support/rowRenders.ts), not from the row.
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";
import type { ConversationListProps } from "../src/pages/home-messages/list/ConversationList";
import type { HomeConversation } from "../src/pages/home-channels/types";

const scope = globalThis as Record<string, unknown>;
let saved: Array<readonly [string, boolean, unknown]> = [];
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    KeyboardEvent: window.KeyboardEvent,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const NOW = new Date(2026, 10, 6, 15, 30).getTime();
const words = {
  untitled: "Conversation",
  yesterday: "Yesterday",
  channel: "Channel",
  mentioned: "Mentions you",
  unread: (n: number) => `${n} unread`,
};

async function mount(count: number) {
  const { ConversationList } = await import("../src/pages/home-messages/list/ConversationList");
  const { ME, sampleConversations } = await import("../src/pages/home-messages/list/fixtures");
  const { listModel } = await import("../src/pages/home-messages/list/model");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const conversations = sampleConversations(count, NOW);
  const modelAt = (map: ReadonlyMap<string, HomeConversation>, now = NOW) =>
    listModel(map, { me: ME.id, now, language: "en-US", words });
  let props: ConversationListProps = {
    model: modelAt(conversations),
    width: 320,
    query: "",
    onQuery: () => {},
    unreadOnly: false,
    onUnreadOnly: () => {},
    strings: createStrings({ en: {} }, ["en"]),
    windowControls: null,
    canPin: true,
    onSelect: () => {},
    onOpen: () => {},
    onSetPinned: () => {},
    onArrangePinned: () => {},
    onMarkRead: () => {},
    onMarkUnread: () => {},
  };
  act(() => root?.unmount());
  rowRenders.clear();
  root = createRoot(host);
  // The page hands the list fresh props (and fresh inline handlers) on each of its renders.
  const render = (patch: Partial<ConversationListProps> = {}) => {
    props = { ...props, onSelect: () => {}, onOpen: () => {}, ...patch };
    act(() => root!.render(createElement(ConversationList, props)));
  };
  render();
  const scroller = host.querySelector<HTMLElement>("[role='listbox']")!;
  Object.defineProperty(scroller, "clientHeight", { configurable: true, value: 600 });
  const scrollTo = (top: number) => {
    Object.defineProperty(scroller, "scrollTop", { configurable: true, writable: true, value: top });
    act(() => {
      scroller.dispatchEvent(new window.Event("scroll"));
    });
  };
  scrollTo(0);
  const mounted = () => [...host.querySelectorAll<HTMLElement>("[data-list-row]")].map((r) => r.dataset.listRow!);
  return { conversations, modelAt, render, scrollTo, mounted, props: () => props };
}

test("a parent render with unchanged data renders no row", async () => {
  const list = await mount(1_000);
  rowRenders.reset();
  list.render();
  expect(rowRenders.count("ListRow")).toBe(0);
  expect(rowRenders.count("PinnedTile")).toBe(0);
});

test("the minute clock (a new model, the same times) renders no row", async () => {
  const list = await mount(1_000);
  rowRenders.reset();
  list.render({ model: list.modelAt(list.conversations, NOW + 20_000) });
  expect(rowRenders.count("ListRow")).toBe(0);
  expect(rowRenders.count("PinnedTile")).toBe(0);
});

test("one conversation's new message renders that row alone", async () => {
  const list = await mount(1_000);
  const id = list.mounted()[3]!;
  const next = new Map(list.conversations);
  next.set(id, { ...next.get(id)!, lastText: "A new line" });
  rowRenders.reset();
  list.render({ model: list.modelAt(next) });
  expect(rowRenders.count("ListRow")).toBe(1);
  expect(rowRenders.count("PinnedTile")).toBe(0);
  expect(host.querySelector(`[data-list-row='${id}'] .hm-row-preview`)?.textContent).toBe("A new line");
});

test("an unread count change renders that row alone, and its accessible label says the new count", async () => {
  const list = await mount(1_000);
  const id = list.mounted()[4]!;
  const before = list.conversations.get(id)!;
  const next = new Map(list.conversations);
  // From some unread to more: the dot stays, only the count (in the label) moves.
  next.set(id, { ...before, unread: before.unread + 2 });
  rowRenders.reset();
  list.render({ model: list.modelAt(next) });
  expect(rowRenders.count("ListRow")).toBe(1);
  expect(rowRenders.count("PinnedTile")).toBe(0);
  expect(host.querySelector(`[data-list-row='${id}']`)?.getAttribute("aria-label")).toContain(
    `${Math.max(before.unread + 2, 1)} unread`,
  );
});

test("selecting a row renders it and the row above (its hairline) alone", async () => {
  const list = await mount(1_000);
  const ids = list.mounted();
  rowRenders.reset();
  list.render({ selected: ids[5] });
  expect(rowRenders.count("ListRow")).toBe(2);
  // Down to the next row: the old one (unselected), the new one, and the hairline above the old one.
  rowRenders.reset();
  list.render({ selected: ids[6] });
  expect(rowRenders.count("ListRow")).toBe(3);
  expect(host.querySelector(`[data-list-row='${ids[6]}']`)?.getAttribute("aria-selected")).toBe("true");
});

test("a scroll step mounts the rows coming into view and renders no other", async () => {
  const list = await mount(1_000);
  const before = new Set(list.mounted());
  rowRenders.reset();
  list.scrollTo(64 * 10);
  const entered = list.mounted().filter((id) => !before.has(id)).length;
  expect(entered).toBeGreaterThan(0);
  expect(rowRenders.count("ListRow")).toBe(entered);
});

test("mounted rows stay the window's at 1,000 and 10,000 conversations", async () => {
  const counts: Record<number, { rows: number; nodes: number }> = {};
  for (const n of [1_000, 10_000]) {
    const list = await mount(n);
    counts[n] = { rows: list.mounted().length, nodes: host.querySelectorAll("*").length };
  }
  console.log(
    `[jsdom] mounted rows / DOM nodes: N=1000 ${JSON.stringify(counts[1_000])}, N=10000 ${JSON.stringify(counts[10_000])}`,
  );
  expect(counts[10_000]!.rows).toBe(counts[1_000]!.rows);
  expect(counts[10_000]!.rows).toBeLessThan(40);
});
