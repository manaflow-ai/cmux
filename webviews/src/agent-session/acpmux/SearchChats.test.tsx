import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSessionEntry } from "./sessionList";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { isSearchChatsKey, SearchChats, searchChats, SEARCH_CHATS_LIMIT } = await import("./SearchChats");
const { SessionSidebar } = await import("./SessionSidebar");

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));

const sessions: AcpmuxSessionEntry[] = [
  { sessionId: "old", displayTitle: "Port the sidebar", cwd: "/src/app", updatedAt: 10 },
  { sessionId: "new", displayTitle: "Fix the checkout page", cwd: "/src/web", updatedAt: 50 },
  { sessionId: "mid", displayTitle: "Fix the sidebar flicker", cwd: "/src/app", updatedAt: 30 },
];
const titles = () => [...doc.querySelectorAll(".acpmux-chat-title")].map((node) => node.textContent);
const key = (target: Element, name: string, init: KeyboardEventInit = {}) =>
  act(async () => {
    target.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...init }),
    );
  });
/// Types into the field through React's onChange (see composer.test.tsx).
function typeInto(node: HTMLInputElement, value: string) {
  node.value = value;
  const props = (node as unknown as Record<string, { onChange(event: { target: HTMLInputElement }): void }>)[
    Object.keys(node).find((name) => name.startsWith("__reactProps$"))!
  ]!;
  props.onChange({ target: node });
}

test("a query keeps chats matching every word, newest first, and lists at most the limit", () => {
  expect(searchChats(sessions, "").map((session) => session.sessionId)).toEqual(["new", "mid", "old"]);
  expect(searchChats(sessions, "fix").map((session) => session.sessionId)).toEqual(["new", "mid"]);
  expect(searchChats(sessions, "sidebar app").map((session) => session.sessionId)).toEqual(["mid", "old"]);
  const many = Array.from({ length: SEARCH_CHATS_LIMIT + 5 }, (_, index) => ({
    sessionId: `s${index}`,
    updatedAt: index,
  }));
  const listed = searchChats(many, "");
  expect(listed).toHaveLength(SEARCH_CHATS_LIMIT);
  expect(listed[0]!.sessionId).toBe(`s${SEARCH_CHATS_LIMIT + 4}`);
});

async function open(onPick: (id: string) => void, onClose = () => {}) {
  await act(async () =>
    root.render(
      createElement(
        "div",
        null,
        createElement("textarea", { id: "prompt" }),
        createElement(SearchChats, { sessions, selectedId: "mid", onPick, onClose }),
      ),
    ),
  );
  return doc.querySelector<HTMLInputElement>(".acpmux-search-chats input")!;
}

test("the palette focuses its field, narrows as you type, and Enter opens the highlighted chat", async () => {
  const picked: string[] = [];
  const field = await open((id) => picked.push(id));
  expect(doc.activeElement).toBe(field);
  expect(titles()).toEqual(["Fix the checkout page", "Fix the sidebar flicker", "Port the sidebar"]);
  // The open chat is marked; its project shows beside the title.
  expect(doc.querySelector("[aria-current=page] .acpmux-chat-title")!.textContent).toBe("Fix the sidebar flicker");
  expect(doc.querySelector(".acpmux-chat-project")!.textContent).toBe("web");
  await act(async () => typeInto(field, "sidebar"));
  expect(titles()).toEqual(["Fix the sidebar flicker", "Port the sidebar"]);
  await key(field, "ArrowDown");
  expect(field.getAttribute("aria-activedescendant")).toBe(doc.querySelectorAll("[role=option]")[1]!.id);
  await key(field, "Enter");
  expect(picked).toEqual(["old"]);
  await act(async () => typeInto(field, "nothing like this"));
  expect(titles()).toEqual([]);
  expect(doc.querySelector(".acpmux-chat-note")!.textContent).toBe("No matching chats");
  await key(field, "Enter");
  expect(picked).toEqual(["old"]);
});

test("Ctrl+digit opens nothing: cmux's window shortcuts own it, so rows show no number", async () => {
  const picked: string[] = [];
  const field = await open((id) => picked.push(id));
  expect(doc.querySelector(".acpmux-search-chats kbd")).toBeNull();
  await key(field, "2", { ctrlKey: true });
  expect(picked).toEqual([]);
});

test("Escape, Tab and a click outside close it, and focus goes back where it was", async () => {
  let closed = 0;
  doc.body.appendChild(Object.assign(doc.createElement("button"), { id: "outside" }));
  await act(async () => root.render(createElement("div", null, createElement("textarea", { id: "prompt" }))));
  doc.getElementById("prompt")!.focus();
  const field = await open(
    () => {},
    () => closed++,
  );
  // Escape stays with the palette: the narrow sidebar's own Escape (on the document) doesn't see it.
  let documentEscapes = 0;
  const spy = (event: KeyboardEvent) => {
    if (event.key === "Escape") documentEscapes++;
  };
  doc.addEventListener("keydown", spy);
  await key(field, "Escape");
  doc.removeEventListener("keydown", spy);
  expect(documentEscapes).toBe(0);
  await key(field, "Tab");
  await act(async () => {
    doc.getElementById("outside")!.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
  });
  expect(closed).toBe(3);
  await act(async () => root.render(createElement("div", null, createElement("textarea", { id: "prompt" }))));
  expect(doc.activeElement).toBe(doc.getElementById("prompt"));
  doc.getElementById("outside")!.remove();
});

test("a press on the opener is left to it, and focus falls back to the prompt when its row was hidden", async () => {
  let closed = 0;
  const shell = (palette: boolean) =>
    createElement(
      "div",
      null,
      createElement("button", { id: "opener", "data-search-chats-opener": "" }),
      createElement("button", { id: "row" }),
      createElement("form", { className: "acpmux-composer" }, createElement("textarea")),
      palette && createElement(SearchChats, { sessions, onPick: () => {}, onClose: () => closed++ }),
    );
  await act(async () => root.render(shell(false)));
  const row = doc.getElementById("row")!;
  row.focus();
  await act(async () => root.render(shell(true)));
  await act(async () => {
    doc.getElementById("opener")!.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
  });
  expect(closed).toBe(0);
  // Picking from the narrow sidebar hides it; the row it was opened from can't hold focus.
  Object.assign(row, { checkVisibility: () => false });
  await act(async () => root.render(shell(false)));
  expect(doc.activeElement).toBe(doc.querySelector(".acpmux-composer textarea"));
});

test("the sidebar's search button opens the palette, and shows only when the pane offers one", async () => {
  let opened = 0;
  await act(async () =>
    root.render(createElement(SessionSidebar, { sessions, onSelect: () => {}, onSearchChats: () => opened++ })),
  );
  const button = doc.querySelector<HTMLButtonElement>(".acpmux-sidebar-search-chats")!;
  expect(button.getAttribute("aria-label")).toBe("Search chats");
  expect(button.getAttribute("aria-keyshortcuts")).toBe("Meta+K");
  // The filter stays beside it.
  expect(doc.querySelector("input[aria-label='Search sessions']")).not.toBeNull();
  await act(async () => button.click());
  expect(opened).toBe(1);
  await act(async () => root.render(createElement(SessionSidebar, { sessions, onSelect: () => {} })));
  expect(doc.querySelector(".acpmux-sidebar-search-chats")).toBeNull();
});

test("plain Cmd+K is the palette's key; Shift, Ctrl, Option or an input method's key is not", () => {
  const press = (init: KeyboardEventInit) => new dom.window.KeyboardEvent("keydown", { key: "k", ...init });
  expect(isSearchChatsKey(press({ metaKey: true }))).toBe(true);
  expect(isSearchChatsKey(press({ key: "K", metaKey: true }))).toBe(true);
  expect(isSearchChatsKey(press({ metaKey: true, shiftKey: true }))).toBe(false);
  expect(isSearchChatsKey(press({ metaKey: true, ctrlKey: true }))).toBe(false);
  expect(isSearchChatsKey(press({ metaKey: true, altKey: true }))).toBe(false);
  expect(isSearchChatsKey(press({ ctrlKey: true }))).toBe(false);
  expect(isSearchChatsKey(press({ metaKey: true, isComposing: true }))).toBe(false);
  // A held Cmd+K toggles once, and the physical K key counts on a non-Latin layout.
  expect(isSearchChatsKey(press({ metaKey: true, repeat: true }))).toBe(false);
  expect(isSearchChatsKey(press({ key: "л", code: "KeyK", metaKey: true }))).toBe(true);
  expect(isSearchChatsKey(press({ key: "л", code: "KeyL", metaKey: true }))).toBe(false);
});
