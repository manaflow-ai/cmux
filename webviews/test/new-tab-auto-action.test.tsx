// Leo 2026-10-20: no Search | Ask switch on the New Tab page: type and press Return. An address
// opens; any other text asks the agent (Leo 2026-10-24: "Search the web. Do you really want that
// first?"), with the web search as the last row. The pick is the first row and Return takes it;
// Down or Tab picks another row for the rare miss. This replaces the Search | Ask switch of
// 2026-10-18 (PR 21817).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import { defaultSelection, screenRows } from "../src/agent-session/acpmux/newtab/screenModel";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

const ask = { harness: "claude", agent: "Claude Code" };
const omnibar = { ...EMPTY_OMNIBAR, workspaces: [{ id: "ws", name: "ff-scratch" }] };

test("keywords and questions both put Ask first and the web search last", () => {
  const rows = screenRows("ff", { omnibar, ask });
  expect(rows.map((row) => row.type)).toEqual(["ask", "workspace", "search"]);
  expect(defaultSelection(rows)).toBe(0);
  expect(screenRows("how do ff work", { omnibar, ask }).map((row) => row.type)).toEqual(["ask", "search"]);
});

test("with no agent, plain text searches first and an address leads with the web search still last", () => {
  expect(screenRows("ff", { omnibar }).map((row) => row.type)).toEqual(["search", "workspace"]);
  const visited = { ...omnibar, history: [{ url: "https://github.com/x" }] };
  expect(screenRows("github.com", { omnibar: visited }).map((row) => row.type)).toEqual(["open", "history", "search"]);
});

test("an address opens first", () => {
  expect(screenRows("reddit.com", { omnibar, ask })[0]?.type).toBe("open");
});

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getSelection",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>").window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

async function render(calls: unknown[][]) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        omnibar={omnibar}
        lastAgent="claude"
        onAsk={(...args) => calls.push(["ask", ...args])}
        onOpen={noop}
        onSearch={(text) => calls.push(["search", text])}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  // The field is the composer's Markdown field: its editor is made a moment after it mounts.
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return field;
}

/// Types `text` into the field and returns its editable element, where keys go.
async function type(field: MarkdownFieldElement, text: string) {
  const handle = field.acpmuxMarkdownField!;
  await act(async () => {
    handle.focus();
    handle.type(text);
  });
  expect(handle.plainText()).toBe(text);
  return field.querySelector<HTMLElement>("[contenteditable]")!;
}

const key = (field: HTMLElement, name: string, shiftKey = false) =>
  act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: name, shiftKey, bubbles: true, cancelable: true }));
  });
const selected = () =>
  [...window.document.querySelectorAll<HTMLElement>('[role="option"]')]
    .find((row) => row.getAttribute("aria-selected") === "true")
    ?.querySelector(".nt-row-title")?.textContent;

test("there is no Search | Ask switch and no Tab hint", async () => {
  const field = await render([]);
  expect(host.querySelector(".nt-mode")).toBeNull();
  expect(host.textContent).not.toContain("Tab to switch");
  // The Markdown field draws its placeholder in its own span (no keycap after it) and labels its
  // editable element with it; nothing describes the field.
  const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
  expect(editor.getAttribute("aria-describedby")).toBeNull();
  expect(field.getAttribute("aria-describedby")).toBeNull();
  expect(editor.getAttribute("aria-label")).toBe("Ask anything or type a URL");
  const placeholder = field.querySelector<HTMLElement>(".acpmux-md-placeholder")!;
  expect(placeholder.textContent).toBe("Ask anything or type a URL");
  expect(placeholder.hidden).toBe(false);
  expect(placeholder.querySelector(".acpmux-md-placeholder-key")).toBeNull();
});

test("Return on keywords asks the composer's agent", async () => {
  const calls: unknown[][] = [];
  const editor = await type(await render(calls), "ff");
  expect(selected()).toBe("Ask Claude Code");
  await key(editor, "Enter");
  expect(calls[0]?.slice(0, 3)).toEqual(["ask", "claude", "ff"]);
});

test("Return on a question asks the composer's agent", async () => {
  const calls: unknown[][] = [];
  const editor = await type(await render(calls), "why is ff slow?");
  expect(selected()).toBe("Ask Claude Code");
  await key(editor, "Enter");
  expect(calls[0]?.slice(0, 3)).toEqual(["ask", "claude", "why is ff slow?"]);
});

test("Down reaches the web search for a miss, and Return takes it", async () => {
  const calls: unknown[][] = [];
  const editor = await type(await render(calls), "ff");
  await key(editor, "ArrowDown");
  await key(editor, "ArrowDown");
  expect(selected()).toBe("Search the web for ff");
  await key(editor, "Enter");
  expect(calls).toEqual([["search", "ff"]]);
});

test("Tab steps the suggestions, and Shift-Tab is not consumed", async () => {
  const editor = await type(await render([]), "ff");
  await key(editor, "Tab");
  expect(selected()).toBe("ff-scratch");
  expect(window.document.activeElement).toBe(editor);
  const event = new window.KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true, cancelable: true });
  await act(async () => void editor.dispatchEvent(event));
  expect(event.defaultPrevented).toBe(false);
});

// Review (PR 22816): Tab never wraps the rows, so it can always leave the field: from the last row
// it is the browser's again.
test("Tab on the last row moves focus on instead of wrapping", async () => {
  const editor = await type(await render([]), "ff");
  // Up from the top row goes back to the text; from there Up takes the last row.
  await key(editor, "ArrowUp");
  await key(editor, "ArrowUp");
  const event = new window.KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
  await act(async () => void editor.dispatchEvent(event));
  expect(event.defaultPrevented).toBe(false);
});
