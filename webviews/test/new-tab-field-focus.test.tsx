// The New Tab field takes the keyboard once when the page shows (and on Cmd-L), never again on its
// own. The App re-renders the page often (snapshots, the clock) and hands it a new input-ready
// callback each time; the page focused and selected the field on every one, so a click into the
// focused field, or any update, restarted the caret blink and selected the text under the caret.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactElement } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

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
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    // ProseMirror's (the New Tab screen's Markdown field): the selection, Node, MutationObserver.
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
    // The New Tab screen's field is the composer's Markdown field (ProseMirror).
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

/// The page's field as a person meets it: the element that takes focus and clicks, typing, the
/// caret, and the selection. The classic page's is an input; the New Tab screen's is the
/// composer's Markdown field, driven through its handle (its editor mounts a moment after it).
type Field = {
  element: HTMLElement;
  type(text: string): void;
  setCaret(offset: number): void;
  selection(): [number, number];
};

async function fieldIn(selector: string): Promise<Field> {
  const found = host.querySelector<HTMLElement>(selector)!;
  if (found instanceof window.HTMLInputElement || found instanceof window.HTMLTextAreaElement) {
    const input = found;
    const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), "value")!.set!;
    return {
      element: input,
      type: (text) => {
        setValue.call(input, text);
        input.dispatchEvent(new window.Event("input", { bubbles: true }));
      },
      setCaret: (offset) => input.setSelectionRange(offset, offset),
      selection: () => [input.selectionStart ?? -1, input.selectionEnd ?? -1],
    };
  }
  const markdown = found as MarkdownFieldElement;
  for (
    let turn = 0;
    turn < 200 && !(markdown.acpmuxMarkdownField && markdown.querySelector("[contenteditable]"));
    turn++
  )
    await settle();
  const handle = markdown.acpmuxMarkdownField!;
  return {
    element: markdown.querySelector<HTMLElement>("[contenteditable]")!,
    type: (text) => {
      handle.type(text);
    },
    setCaret: (offset) => handle.setCaret(offset),
    selection: () => {
      const { selectionStart, selectionEnd } = handle.text();
      return [selectionStart, selectionEnd];
    },
  };
}

/// Shows a page as the App does (a new inline input-ready callback on every render), places the
/// caret in typed text, then re-renders and clicks the focused field as a person would.
async function caretAfterUpdates(page: (onInputReady: (token: string) => void) => ReactElement, selector: string) {
  const { createRoot } = await import("react-dom/client");
  const ready: string[] = [];
  const root: Root = createRoot(host);
  const render = () => root.render(page((token) => ready.push(token)));
  try {
    await act(async () => render());
    const field = await fieldIn(selector);
    const element = field.element;
    expect(window.document.activeElement).toBe(element);
    await act(async () => field.type("hello world"));
    await act(async () => field.setCaret(3));
    let focused = 0;
    element.addEventListener("focus", () => (focused += 1));
    const focus = element.focus.bind(element);
    element.focus = (options?: FocusOptions) => {
      focused += 1;
      focus(options);
    };
    // The App re-renders the page; then a click lands in the field that already has focus.
    await act(async () => render());
    await act(async () => render());
    await act(async () => {
      element.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true }));
      element.dispatchEvent(new window.MouseEvent("mouseup", { bubbles: true }));
      element.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
    });
    await settle();
    return { focused, selection: field.selection(), ready };
  } finally {
    await act(async () => root.unmount());
  }
}

test("a prefilled New Tab location is selected only after the editor is ready", async () => {
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const ready: string[] = [];
  const root: Root = (await import("react-dom/client")).createRoot(host);
  const location = "https://example.com/a-long-prefilled-location";
  const render = () =>
    root.render(
      <NewTabScreen
        snapshot={noChat()}
        location={location}
        inputToken="token-location"
        onInputReady={(token) => ready.push(token)}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    );
  try {
    await act(async () => render());
    const field = await fieldIn(".nt-field");
    expect(field.selection()).toEqual([0, location.length]);
    expect(ready).toEqual(["token-location"]);
    field.type("x");
    await settle();
    const markdown = host.querySelector<MarkdownFieldElement>(".nt-field")!.acpmuxMarkdownField!;
    expect(markdown.plainText()).toBe("x");
    await act(async () => render());
    await settle();
    expect(ready).toEqual(["token-location"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the New Tab screen keeps the caret where it is across updates and a click into its field", async () => {
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const result = await caretAfterUpdates(
    (onInputReady) => (
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        inputToken="token-1"
        onInputReady={onInputReady}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />
    ),
    ".nt-field",
  );
  expect(result).toEqual({ focused: 0, selection: [3, 3], ready: ["token-1"] });
});

test("the classic New Tab page keeps the caret where it is across updates and a click into its field", async () => {
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const result = await caretAfterUpdates(
    (onInputReady) => (
      <NewTabPage
        snapshot={noChat()}
        inputToken="token-1"
        onInputReady={onInputReady}
        onSubmit={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />
    ),
    ".acpmux-newtab-field",
  );
  expect(result).toEqual({ focused: 0, selection: [3, 3], ready: ["token-1"] });
});
