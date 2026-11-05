// The New Tab field edits like a browser's omnibar (cx-ag5.8, R116): Option- and Cmd-Backspace,
// Option- and Cmd-arrows, Ctrl-A/E/K are the text field's own (WebKit does them; the page must not
// take them). Up and Down (and Ctrl-N/P) step the suggestions, but a modified arrow moves or extends
// the caret, as in Safari's and Chrome's address bars: Shift-Down selected the next row instead.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
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
  "MutationObserver",
  "getSelection",
  "Element",
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
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    // The suggestions' Popover (Base UI and Floating UI) reads these.
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
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

async function render(calls: unknown[][]) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { omnibarContext } = await import("../src/agent-session/acpmux/omnibar");
  act(() => root?.unmount());
  root = createRoot(host);
  const omnibar = omnibarContext({
    ...EMPTY_OMNIBAR,
    tabs: [
      { id: "blank", kind: "browser", title: "about:blank", detail: "about:blank", workspace: "workspace-3" },
      { id: "docs", kind: "browser", title: "Reddit docs", detail: "docs.example.com", workspace: "notes" },
    ],
    workspaces: [{ id: "ws-reddit", name: "reddit-scraper", detail: "~/src/reddit-scraper" }],
    history: [{ url: "about:blank" }],
  });
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        omnibar={omnibar}
        lastAgent="claude"
        onAsk={(...args) => calls.push(["ask", ...args])}
        onOpen={(url) => calls.push(["open", url])}
        onSearch={(text) => calls.push(["search", text])}
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
  const handle = field.acpmuxMarkdownField!;
  await act(async () => {
    handle.focus();
    handle.type(text);
  });
  return field.querySelector<HTMLElement>("[contenteditable]")!;
}

const rows = () => [...window.document.querySelectorAll<HTMLElement>('[role="option"]')];

const selected = () => rows().findIndex((row) => row.getAttribute("aria-selected") === "true");
async function press(field: HTMLElement, key: string, modifiers: Partial<KeyboardEventInit> = {}) {
  const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...modifiers });
  await act(async () => field.dispatchEvent(event));
  return event;
}

test("Up and Down step the suggestions", async () => {
  await render([]);
  const field = await type("reddit");
  expect(rows().length).toBeGreaterThan(1);
  expect(selected()).toBe(0);
  expect((await press(field, "ArrowDown")).defaultPrevented).toBe(true);
  expect(selected()).toBe(1);
  await press(field, "ArrowUp");
  expect(selected()).toBe(0);
});

test("a modified arrow moves or extends the caret, not the highlight", async () => {
  await render([]);
  const field = await type("reddit");
  for (const modifiers of [
    { shiftKey: true },
    { metaKey: true },
    { altKey: true },
    { metaKey: true, shiftKey: true },
  ]) {
    for (const key of ["ArrowDown", "ArrowUp"]) {
      const event = await press(field, key, modifiers);
      expect({ key, modifiers, taken: event.defaultPrevented }).toEqual({ key, modifiers, taken: false });
      expect(selected()).toBe(0);
    }
  }
});

test("the omnibar's editing keys stay the field's", async () => {
  await render([]);
  const field = await type("reddit scraper");
  const editing: [string, Partial<KeyboardEventInit>][] = [
    ["Backspace", { altKey: true }],
    ["Backspace", { metaKey: true }],
    ["ArrowLeft", { altKey: true }],
    ["ArrowRight", { metaKey: true }],
    ["ArrowLeft", { altKey: true, shiftKey: true }],
    ["a", { ctrlKey: true }],
    ["e", { ctrlKey: true }],
    ["k", { ctrlKey: true }],
  ];
  for (const [key, modifiers] of editing) {
    const event = await press(field, key, modifiers);
    // MarkdownField owns Select All in its ProseMirror keymap; browser-native editing keys
    // continue through without the New Tab's suggestion handler taking them.
    expect({ key, modifiers, taken: event.defaultPrevented }).toEqual({
      key,
      modifiers,
      taken: modifiers.ctrlKey === true && key === "a",
    });
  }
  expect(selected()).toBe(0);
});

test("the New Tab composer follows the opt-in spell checking setting", async () => {
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings({ spellChecking: false });
  await render([]);
  expect(
    host
      .querySelector<MarkdownFieldElement>(".nt-field")
      ?.querySelector("[contenteditable]")
      ?.getAttribute("spellcheck"),
  ).toBe("false");
  await act(async () => setComposerSettings({ spellChecking: true }));
  expect(
    host
      .querySelector<MarkdownFieldElement>(".nt-field")
      ?.querySelector("[contenteditable]")
      ?.getAttribute("spellcheck"),
  ).toBe("true");
  await act(async () => setComposerSettings({ spellChecking: false }));
});
