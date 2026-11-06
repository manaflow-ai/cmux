// l10n-allow-file: test fixtures.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createStrings } from "../../shared/i18n";
import { ConversationList, type ConversationListProps } from "./ConversationList";
import { ME, sampleConversations } from "./fixtures";
import { listModel } from "./model";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(globals)) saved.set(key, scope[key]);
  Object.assign(scope, globals);
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const NOW = new Date(2026, 10, 6, 15, 30).getTime();
const strings = createStrings({ en: {} }, ["en"]);
const words = {
  untitled: "Conversation",
  yesterday: "Yesterday",
  channel: "Channel",
  mentioned: "Mentions you",
  unread: (n: number) => `${n} unread`,
};

async function mount(count: number, extra: Partial<ConversationListProps> = {}) {
  const element = installDom();
  const calls: string[] = [];
  const model = listModel(sampleConversations(count, NOW), { me: ME.id, now: NOW, language: "en-US", words });
  const props: ConversationListProps = {
    model,
    width: 320,
    query: "",
    onQuery: (q) => calls.push(`query:${q}`),
    unreadOnly: false,
    onUnreadOnly: (on) => calls.push(`unread:${on}`),
    strings,
    windowControls: null,
    canPin: true,
    onSelect: (id) => calls.push(`select:${id}`),
    onOpen: (id) => calls.push(`open:${id}`),
    onSetPinned: (id, on) => calls.push(`pin:${id}:${on}`),
    onArrangePinned: (order) => calls.push(`arrange:${order.join(",")}`),
    onMarkRead: (id) => calls.push(`read:${id}`),
    onMarkUnread: (id) => calls.push(`markUnread:${id}`),
    ...extra,
  };
  root = createRoot(element);
  await act(async () => root!.render(<ConversationList {...props} />));
  return { element, calls };
}

test("10,000 conversations put only the rows in view in the DOM", async () => {
  const { element } = await mount(10_000);
  const rows = element.querySelectorAll("[data-list-row]").length;
  expect(element.querySelectorAll("[data-pinned-tile]").length).toBe(4);
  expect(rows).toBeGreaterThan(5);
  expect(rows).toBeLessThan(40);
});

test("Up and Down select through the grid then the rows; Return opens", async () => {
  const { element, calls } = await mount(3, { selected: "c-casey" });
  const list = element.querySelector<HTMLElement>("[role='listbox']")!;
  const key = (key: string) =>
    act(async () => {
      list.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true }));
    });
  await key("ArrowDown");
  await key("ArrowUp");
  await key("Enter");
  expect(calls).toEqual(["select:c-design", "select:c-morgan", "open:c-casey"]);
});

test("typing a letter in the list starts a search", async () => {
  const { element, calls } = await mount(3);
  const list = element.querySelector<HTMLElement>("[role='listbox']")!;
  await act(async () => {
    list.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "t", bubbles: true }));
  });
  expect(calls).toEqual(["query:t"]);
});

test("a click opens; a Command-click only selects", async () => {
  const { element, calls } = await mount(3);
  const row = element.querySelector<HTMLElement>("[data-list-row='c-design']")!;
  await act(async () => {
    row.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
    row.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, metaKey: true }));
  });
  expect(calls).toEqual(["select:c-design", "open:c-design", "select:c-design"]);
});
