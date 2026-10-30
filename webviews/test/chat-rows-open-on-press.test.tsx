// Lawrence 2026-10-19: "mouse down to immediately open". Chat rows in the agent pane open on the
// press, as the native sidebar rows and tabs do: a plain press opens the chat at once and the click
// that follows does not open it again. A keyboard click (Enter, Space) still opens it, and a
// Cmd- or Shift-click selects on the release without opening (the Finder rule).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const saved: (readonly [string, boolean, unknown])[] = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
  const { window } = dom;
  // TanStack Virtual sizes the All chats list from its scroller; JSDOM lays nothing out.
  window.HTMLElement.prototype.getBoundingClientRect = () =>
    ({ x: 0, y: 0, top: 0, left: 0, right: 600, bottom: 800, width: 600, height: 800, toJSON() {} }) as DOMRect;
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => 800 });
  Object.defineProperty(window.HTMLElement.prototype, "offsetWidth", { configurable: true, get: () => 600 });
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  const replacements: Record<string, unknown> = {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    MutationObserver: window.MutationObserver,
    ResizeObserver: window.ResizeObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.getOwnPropertyNames(window))
    if (
      /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
      !(key in scope)
    )
      replacements[key] = (window as unknown as Record<string, unknown>)[key];
  saved.push(...Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const));
  Object.assign(scope, replacements);
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Mods = { metaKey?: boolean; shiftKey?: boolean };

/// A press on `element`: mousedown only, as the user holds the button.
const press = (element: Element, mods: Mods = {}) =>
  act(async () => {
    element.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0, detail: 1, ...mods }));
  });

/// The release that follows a press: mouseup, then the click the browser sends.
const release = (element: Element, mods: Mods = {}) =>
  act(async () => {
    element.dispatchEvent(new window.MouseEvent("mouseup", { bubbles: true, button: 0, detail: 1, ...mods }));
    element.dispatchEvent(new window.MouseEvent("click", { bubbles: true, button: 0, detail: 1, ...mods }));
  });

/// Enter or Space on a focused button: a click with `detail` 0 and no press.
const keyboardClick = (element: Element) =>
  act(async () => {
    element.dispatchEvent(new window.MouseEvent("click", { bubbles: true, button: 0, detail: 0 }));
  });

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

const chats = [
  { key: "a", harness: "claude", title: "Retry uploads", cwd: "/Users/me/src/uploader", updatedAt: 9 },
  { key: "b", harness: "claude", title: "Fix the sidebar", cwd: "/Users/me/src/cmux", updatedAt: 8 },
];

const allChatsRow = (title: string) =>
  [...host.querySelectorAll<HTMLElement>(".nt-all-row")].find(
    (row) => row.querySelector(".nt-all-title")?.textContent === title,
  )!;

test("an All chats row opens on the press, once; a keyboard click still opens it", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const opened: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(<AllChatsList load={async () => ({ chats, ready: true })} onOpen={(key) => opened.push(key)} />),
  );
  await settle();
  const row = allChatsRow("Fix the sidebar");
  await press(row);
  expect(opened).toEqual(["b"]);
  await release(row);
  expect(opened).toEqual(["b"]);
  await keyboardClick(row);
  expect(opened).toEqual(["b", "b"]);
});

test("a Cmd-click on an All chats row selects it on the release and opens nothing (the Finder rule)", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const opened: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <AllChatsList
        load={async () => ({ chats, ready: true })}
        onOpen={(key) => opened.push(key)}
        onBring={() => {}}
      />,
    ),
  );
  await settle();
  const row = allChatsRow("Retry uploads");
  await press(row, { metaKey: true });
  expect(row.hasAttribute("data-selected")).toBe(false);
  await release(row, { metaKey: true });
  expect(allChatsRow("Retry uploads").hasAttribute("data-selected")).toBe(true);
  expect(opened).toEqual([]);
});

test("a press on a row of a multi-selection waits for the release, so the selection can still be dragged", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const opened: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <AllChatsList
        load={async () => ({ chats, ready: true })}
        onOpen={(key) => opened.push(key)}
        onBring={() => {}}
      />,
    ),
  );
  await settle();
  for (const title of ["Retry uploads", "Fix the sidebar"]) {
    await press(allChatsRow(title), { metaKey: true });
    await release(allChatsRow(title), { metaKey: true });
  }
  const row = allChatsRow("Fix the sidebar");
  await press(row);
  expect(opened).toEqual([]);
  await release(row);
  expect(opened).toEqual(["b"]);
});

test("a Recently Closed row reopens on the press, once", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ClosedList } = await import("../src/agent-session/acpmux/newtab/ClosedList");
  const reopened: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ClosedList
        items={[{ id: "closed-1", title: "Old tab", kind: "terminal", closedAt: 1, available: true }]}
        onReopen={(id) => reopened.push(id)}
      />,
    ),
  );
  const row = host.querySelector(".nt-row")!;
  await press(row);
  expect(reopened).toEqual(["closed-1"]);
  await release(row);
  expect(reopened).toEqual(["closed-1"]);
});

test("Enter on a failed history-page retry keeps the selection shortcut out of the way", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const pageRows = Array.from({ length: 8 }, (_, index) => ({
    key: `page-${index}`,
    harness: "claude",
    title: `History ${index}`,
    cwd: "/Users/me/src/cmux",
    updatedAt: 10 - index,
  }));
  const requests: {
    cursor?: string;
    reject(error: unknown): void;
    resolve(value: { chats: typeof pageRows; nextCursor?: string; ready?: boolean }): void;
  }[] = [];
  const load = (params: { cursor?: string }) =>
    new Promise<{ chats: typeof pageRows; nextCursor?: string; ready?: boolean }>((resolve, reject) => {
      requests.push({ cursor: params.cursor, resolve, reject });
    });
  const opened: string[] = [];
  const brought: string[][] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <AllChatsList load={load} onOpen={(key) => opened.push(key)} onBring={(keys) => brought.push(keys)} />,
    ),
  );
  await act(async () => requests[0]!.resolve({ chats: pageRows, nextCursor: "page-2", ready: true }));
  await settle();
  expect(requests).toHaveLength(2);
  await act(async () => requests[1]!.reject(new Error("daemon unavailable")));
  await settle();

  const row = allChatsRow("History 0");
  await release(row, { metaKey: true });
  const retry = host.querySelector<HTMLButtonElement>(".nt-chats-retry")!;
  retry.focus();
  const enter = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Enter" });
  retry.dispatchEvent(enter);
  expect(enter.defaultPrevented).toBe(false);
  expect(brought).toEqual([]);
  await act(async () => retry.click());
  expect(requests).toHaveLength(3);
  expect(requests[2]!.cursor).toBe("page-2");
  expect(opened).toEqual([]);
});

test("Enter and Escape still operate on a focused selected chat row", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const brought: string[][] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <AllChatsList
        load={async () => ({ chats, ready: true })}
        onOpen={() => {}}
        onBring={(keys) => brought.push(keys)}
      />,
    ),
  );
  await settle();
  for (const title of ["Retry uploads", "Fix the sidebar"]) {
    await press(allChatsRow(title), { metaKey: true });
    await release(allChatsRow(title), { metaKey: true });
  }
  const row = allChatsRow("Fix the sidebar");
  row.focus();
  const enter = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Enter" });
  row.dispatchEvent(enter);
  expect(enter.defaultPrevented).toBe(true);
  expect(brought).toEqual([["a", "b"]]);

  for (const title of ["Retry uploads", "Fix the sidebar"]) {
    await press(allChatsRow(title), { metaKey: true });
    await release(allChatsRow(title), { metaKey: true });
  }
  const escape = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Escape" });
  await act(async () => allChatsRow("Retry uploads").dispatchEvent(escape));
  expect(escape.defaultPrevented).toBe(true);
  expect(host.querySelectorAll(".nt-all-row[data-selected]")).toHaveLength(0);
});
