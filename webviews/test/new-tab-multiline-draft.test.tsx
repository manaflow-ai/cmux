// A multiline draft on the New Tab field, like the chat composer and Codex: Shift-Return adds a
// line instead of sending, and Return sends the whole draft with its line breaks. The field was an
// omnibar <input> where Shift-Return sent too, so a multiline prompt could only come in by paste.
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
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
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
    // The suggestions' Popover (Base UI and Floating UI) reads these.
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
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

async function press(field: HTMLElement, key: string, modifiers: Partial<KeyboardEventInit> = {}) {
  const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...modifiers });
  await act(async () => field.dispatchEvent(event));
  return event;
}

const draft = "Refactor the retry loop\nKeep the backoff\nAdd a test";

test("Shift-Return adds a line instead of sending", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("Refactor the retry loop");
  await press(field, "Enter", { shiftKey: true });
  // The page leaves Shift-Return to the field (the Markdown field's own keymap adds the line and
  // takes the key's default): nothing is sent, and the draft now has a second line.
  const handle = host.querySelector<MarkdownFieldElement>(".nt-field")!.acpmuxMarkdownField!;
  expect({ calls, text: JSON.stringify(handle.plainText()) }).toEqual({
    calls: [],
    text: JSON.stringify("Refactor the retry loop\n"),
  });
});

test("Return sends the whole multiline draft, line breaks kept", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type(draft);
  const event = await press(field, "Enter");
  expect(event.defaultPrevented).toBe(true);
  const ask = calls.find((call) => call[0] === "ask");
  expect(ask?.[2]).toBe(draft);
});
