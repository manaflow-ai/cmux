// Leo 2026-10-18 (photo, "ff" typed in New Tab): the suggestions offered "Ask Claude Code", the web
// search and the workspaces, but New terminal, New browser tab and New chat only as buttons under
// the field, hidden behind the open list. Leo 2026-10-24 ("the new terminal, new browser tab, new
// tab. Like is there a better sort of UI we can do for this where it's just less annoying?"): they
// stay one click away while the list shows, as one quiet strip under the rows, and a row only when
// the text names one ("new t"). The chat-first order keeps the three rows.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { EMPTY_OMNIBAR, type OmnibarContext } from "../src/agent-session/acpmux/omnibar";
import { inStrip, screenRows, type ScreenRow } from "../src/agent-session/acpmux/newtab/screenModel";
import type { SuggestionOrder } from "../src/agent-session/acpmux/newtab/suggestionOrder";

const ask = { harness: "claude", agent: "Claude Code", model: "Claude Opus 5.5" };
const create = ["terminal", "browser", "chat"] as const;
const context = (fields: Partial<OmnibarContext> = {}, order?: SuggestionOrder) => ({
  omnibar: { ...EMPTY_OMNIBAR, ...fields },
  ask,
  create,
  ...(order ? { order } : {}),
});
const kinds = (rows: ScreenRow[]) =>
  rows.filter((row) => !inStrip(row)).map((row) => (row.type === "create" ? `create:${row.kind}` : row.type));
const createStrip = (rows: ScreenRow[]) =>
  rows.flatMap((row) => (row.type === "create" && inStrip(row) ? [row.kind] : []));
const scratch = { workspaces: [{ id: "ws", name: "ff-scratch" }] };

test("a prompt's create actions are the strip under the rows, not three rows", () => {
  const rows = screenRows("ff", context(scratch));
  expect(kinds(rows)).toEqual(["ask", "workspace", "search"]);
  expect(createStrip(rows)).toEqual(["terminal", "browser", "chat"]);
});

test("an address keeps its top hit, Ask and the web search, and the strip", () => {
  const rows = screenRows("reddit.com", context());
  expect(kinds(rows)).toEqual(["open", "ask", "search"]);
  expect(createStrip(rows)).toEqual(["terminal", "browser", "chat"]);
});

test("text that names a create action lists it as a row, and the strip keeps the rest", () => {
  const rows = screenRows("term", context());
  expect(kinds(rows)).toEqual(["ask", "search", "create:terminal"]);
  expect(createStrip(rows)).toEqual(["browser", "chat"]);
  expect(kinds(screenRows("new", context())).slice(-3)).toEqual(["create:terminal", "create:browser", "create:chat"]);
  // One letter names nothing.
  expect(kinds(screenRows("n", context()))).toEqual(["ask", "search"]);
});

test("the chat-first order ends with the three create rows; minimal shows none while typing", () => {
  const chat = screenRows("ff", context(scratch, "chat"));
  expect(kinds(chat)).toEqual(["ask", "workspace", "search", "create:terminal", "create:browser", "create:chat"]);
  expect(createStrip(chat)).toEqual([]);
  const minimal = screenRows("new", context({}, "minimal"));
  expect(kinds(minimal).filter((kind) => kind.startsWith("create:"))).toEqual([]);
  expect(createStrip(minimal)).toEqual([]);
});

test("the strip rows come last, so the arrow keys reach them after the rows", () => {
  const rows = screenRows("ff", context(scratch));
  expect(rows.slice(-3).map(inStrip)).toEqual([true, true, true]);
  expect(rows.slice(0, -3).some(inStrip)).toBe(false);
});

test("an empty field and shell mode still show no rows and no strip", () => {
  expect(screenRows("", context())).toEqual([]);
  expect(screenRows("!ls", context())).toEqual([]);
  expect(createStrip(screenRows("", context()))).toEqual([]);
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
  "MutationObserver",
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
        omnibar={{ ...EMPTY_OMNIBAR, workspaces: [{ id: "ws", name: "ff-scratch" }] }}
        lastAgent="claude"
        onAsk={(...args) => calls.push(["ask", ...args])}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
        onCreate={(kind) => calls.push(["create", kind])}
      />,
    ),
  );
}

async function type(text: string) {
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const handle = field.acpmuxMarkdownField!;
  await act(async () => {
    handle.focus();
    handle.type(text);
  });
  expect(handle.value()).toBe(text);
  return field.querySelector<HTMLElement>("[contenteditable]")!;
}

const rows = () => [...window.document.querySelectorAll<HTMLElement>('[role="option"]')];
const label = (row: HTMLElement) => row.querySelector(".nt-row-title")?.textContent ?? "";

const strip = () => [...window.document.querySelectorAll<HTMLElement>(".nt-create-strip-item")];
const listRows = () => rows().filter((row) => !row.classList.contains("nt-create-strip-item"));

test('typing "ff" lists Ask, the workspace and the web search, with the create strip under them', async () => {
  await render([]);
  await type("ff");
  expect(listRows().map(label)).toEqual(["Ask Claude Code", "ff-scratch", "Search the web for ff"]);
  // The strip's actions are options too: the arrow keys and the native popup reach them.
  expect(strip().map(label)).toEqual(["New terminal", "New browser tab", "New chat"]);
  expect(strip().every((item) => item.getAttribute("role") === "option")).toBe(true);
});

test("a create action opens what its button opens, from the strip or a named row", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  await type("ff");
  const terminal = strip().find((item) => label(item) === "New terminal")!;
  await act(async () => terminal.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 })));
  expect(calls).toEqual([["create", "terminal"]]);

  calls.length = 0;
  await render(calls);
  // Up from the top row goes back to the text; from there Up takes the last row, the strip's New
  // chat, which Return takes.
  const field2 = await type("ff");
  for (let press = 0; press < 2; press += 1)
    await act(async () =>
      field2.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true, cancelable: true })),
    );
  const selected = rows().find((row) => row.getAttribute("aria-selected") === "true")!;
  expect(label(selected)).toBe("New chat");
  await act(async () =>
    field2.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
  );
  expect(calls).toEqual([["ask", "claude", "ff", undefined, "claude-opus-5-5"]]);
});
