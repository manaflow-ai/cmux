// Leo 2026-10-31, "helo" typed in New Tab with the suggestions open and the pointer resting on New
// browser tab: "and i cant even press enter on that hello anymore it doesnt send it to claude".
// Earlier reports of the same trap: Leo 2026-10-20 "this doenstr rwork? i cant click enter";
// Lawrence 2026-10-28 "up arrow ctrl n/p etc clicking enter doesnt work".
//
// A row the pointer passed over took Return: the rows' mouse move picked the hovered row as the
// keyboard's highlight. Now Return with typed text asks the agent (the Ask row) unless the keyboard
// moved the highlight (arrows, Tab, Ctrl-N/P). The pointer only lights the row it is on; a click still
// runs the row it presses.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import type { SuggestionOrder } from "../src/agent-session/acpmux/newtab/suggestionOrder";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
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
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    // The suggestions' Popover (Base UI and Floating UI) reads these.
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
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
const ASK_HELO = ["ask", "claude", "helo", undefined, "claude-opus-5-5"];

async function render(calls: unknown[][], order?: SuggestionOrder) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        {...(order ? { suggestionOrder: order } : {})}
        onAsk={(...args) => calls.push(["ask", ...args])}
        onOpen={(url) => calls.push(["open", url])}
        onSearch={(text) => calls.push(["search", text])}
        onCreate={(kind) => calls.push(["create", kind])}
        onShell={noop}
        onJump={(target, id) => calls.push(["jump", target, id])}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
}

async function type(text: string) {
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const handle = field.acpmuxMarkdownField!;
  const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
  await act(async () => {
    handle.writeText(text, text.length, text.length);
    editor.focus();
    handle.setCaret(text.length);
  });
  return editor;
}

const rows = () => [...window.document.querySelectorAll<HTMLElement>('[role="option"]')];
const title = (row: HTMLElement) => row.querySelector(".nt-row-title")?.textContent ?? "";
const row = (name: string) => rows().find((option) => title(option) === name)!;
const returnTarget = () =>
  rows()
    .filter((option) => option.getAttribute("aria-selected") === "true")
    .map(title);

/// The pointer comes to rest on `option`, as a mouse moved over the open list does.
async function hover(option: HTMLElement) {
  await act(async () => {
    for (const type of ["mouseover", "mouseenter", "mousemove"])
      option.dispatchEvent(new window.MouseEvent(type, { bubbles: type !== "mouseenter", cancelable: true }));
  });
}

async function press(field: HTMLElement, key: string, init: KeyboardEventInit = {}) {
  const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
  await act(async () => field.dispatchEvent(event));
  return event;
}

for (const order of [undefined, "chat"] as const) {
  const where = order === "chat" ? "rows" : "strip";
  test(`Return sends the prompt to Claude while the pointer rests on New browser tab (${where})`, async () => {
    const calls: unknown[][] = [];
    await render(calls, order);
    const field = await type("helo");
    expect(title(rows()[0]!)).toBe("Ask Claude Code");
    await hover(row("New browser tab"));
    // The hovered row is not Return's: the Ask row keeps the highlight the keyboard reads.
    expect(returnTarget()).toEqual(["Ask Claude Code"]);
    expect(field.getAttribute("aria-activedescendant")).toBe(rows()[0]!.id);
    const enter = await press(field, "Enter");
    expect(enter.defaultPrevented).toBe(true);
    expect(calls).toEqual([ASK_HELO]);
  });
}

test("Return sends after the pointer swept over every row", async () => {
  const calls: unknown[][] = [];
  await render(calls, "chat");
  const field = await type("helo");
  // Down the list and back up to the web search: the pointer last rests on a row Return must not take.
  for (const option of rows()) await hover(option);
  await hover(row("Search the web for helo"));
  await press(field, "Enter");
  expect(calls).toEqual([ASK_HELO]);
});

test("Return with the list open and no hover sends the prompt", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("helo");
  expect(rows().length).toBeGreaterThan(1);
  await press(field, "Enter");
  expect(calls).toEqual([ASK_HELO]);
});

test("Down to the web search, then Return, searches", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("helo");
  await press(field, "ArrowDown");
  expect(returnTarget()).toEqual(["Search the web for helo"]);
  await press(field, "Enter");
  expect(calls).toEqual([["search", "helo"]]);
});

test("typing again after a Down pick hands Return back to the Ask row", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("helo");
  await press(field, "ArrowDown");
  expect(returnTarget()).toEqual(["Search the web for helo"]);
  await type("helo there");
  expect(returnTarget()).toEqual(["Ask Claude Code"]);
  await press(field, "Enter");
  expect(calls).toEqual([["ask", "claude", "helo there", undefined, "claude-opus-5-5"]]);
});

test("a keyboard pick stands while the pointer rests on another row", async () => {
  const calls: unknown[][] = [];
  await render(calls, "chat");
  const field = await type("helo");
  await press(field, "ArrowDown");
  await hover(row("New browser tab"));
  expect(returnTarget()).toEqual(["Search the web for helo"]);
  await press(field, "Enter");
  expect(calls).toEqual([["search", "helo"]]);
});

test("Ctrl-N and Ctrl-P move the highlight, and Return runs the row they reached", async () => {
  const calls: unknown[][] = [];
  await render(calls, "chat");
  const field = await type("helo");
  const order = rows().map(title);
  const terminal = order.indexOf("New terminal");
  expect(terminal).toBeGreaterThan(0);
  for (let step = 0; step < terminal + 1; step += 1) await press(field, "n", { ctrlKey: true });
  expect(returnTarget()).toEqual([order[terminal + 1]]);
  await press(field, "p", { ctrlKey: true });
  expect(returnTarget()).toEqual(["New terminal"]);
  await hover(row("Ask Claude Code"));
  await press(field, "Enter");
  expect(calls).toEqual([["create", "terminal"]]);
});

test("a click still runs the row it presses", async () => {
  const calls: unknown[][] = [];
  await render(calls, "chat");
  await type("helo");
  const browser = row("New browser tab");
  await hover(browser);
  await act(async () => browser.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true })));
  expect(calls).toEqual([["create", "browser"]]);
});

// The classic New Tab page's suggestions had the same trap: its rows' mouse move took Return too.
async function classicEnter(hoverOther: boolean) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  act(() => root?.unmount());
  root = createRoot(host);
  const submitted: unknown[][] = [];
  await act(async () =>
    root!.render(
      <NewTabPage
        snapshot={noChat()}
        lastAgent="claude"
        omnibar={{ ...EMPTY_OMNIBAR, workspaces: [{ id: "ws-helo", name: "helo-app" }] }}
        onSubmit={(...args) => {
          submitted.push(args);
        }}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  const field = host.querySelector<HTMLInputElement>(".acpmux-newtab-field")!;
  await act(async () => field.focus());
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, "helo");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  const options = rows();
  expect(options.length).toBeGreaterThan(1);
  const target = options.findIndex((option) => option.getAttribute("aria-selected") === "true");
  expect(target).toBeGreaterThanOrEqual(0);
  if (hoverOther) await hover(options.find((_, index) => index !== target)!);
  expect(rows().findIndex((option) => option.getAttribute("aria-selected") === "true")).toBe(target);
  // Return in the field submits its form (implicit submission, which jsdom does not run for a
  // dispatched key): the keydown, then the form's submit.
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    field.form!.requestSubmit();
  });
  return submitted;
}

test("classic New Tab: Return does what it did before the pointer rested on another row", async () => {
  const plain = await classicEnter(false);
  expect(plain.length).toBe(1);
  expect(await classicEnter(true)).toEqual(plain);
});
