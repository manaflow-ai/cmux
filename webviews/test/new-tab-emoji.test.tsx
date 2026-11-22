// The New Tab field's `:` emoji list, the chat composer's lifecycle (composer/useEmojiCompletion.tsx):
// Leo, 2026-11-22: "for some reason i can't do :pleading_face: with the emoji here. we need to
// actually improve the ergonomics and lifecycle of that." New Tab had no emoji list at all.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { loadEmojiShortcodes } from "../src/agent-session/acpmux/emojiShortcodes";
import { teardownDom } from "./support/domTeardown";

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
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  }).window;
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
    localStorage: window.localStorage,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
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

/// Types `text` a key at a time (through the field's `onBeforeInput`, as keys go), then lets the
/// emoji table and React's work after it land.
async function type(text: string) {
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  const handle = field.acpmuxMarkdownField!;
  await act(async () => handle.focus());
  for (const letter of text) await act(async () => handle.insertTyped(letter));
  await act(async () => {
    await loadEmojiShortcodes();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  return { editor: field.querySelector<HTMLElement>("[contenteditable]")!, handle };
}

const rows = () =>
  [...host.querySelectorAll<HTMLElement>("#acpmux-emoji-menu .acpmux-emoji-row")].map((row) =>
    row.getAttribute("aria-label"),
  );

async function press(field: HTMLElement, key: string, modifiers: Partial<KeyboardEventInit> = {}) {
  const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...modifiers });
  await act(async () => field.dispatchEvent(event));
  return event;
}

beforeEach(() => localStorage.removeItem("cmux.acpmux.recentEmoji"));

test("`:plead` on a later line lists 🥺; Return writes it and a space, and never sends", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const { editor, handle } = await type("Refactor the retry loop");
  await press(editor, "Enter", { shiftKey: true });
  await type(":plead");
  expect(rows()[0]).toBe("🥺 :pleading_face:");
  const event = await press(editor, "Enter");
  expect(event.defaultPrevented).toBe(true);
  expect(calls.filter((call) => call[0] === "ask")).toEqual([]);
  expect(rows()).toEqual([]);
  expect(handle.plainText()).toBe("Refactor the retry loop\n🥺 ");
  await act(async () => handle.undo());
  expect(handle.plainText()).toBe("Refactor the retry loop\n:plead");
});

test("Esc closes the list and Return then sends the text as typed", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const { editor } = await type("ship it :tada");
  expect(rows()[0]).toBe("🎉 :tada:");
  await press(editor, "Escape");
  expect(rows()).toEqual([]);
  await press(editor, "Enter");
  expect(calls.find((call) => call[0] === "ask")?.[2]).toBe("ship it :tada");
});

test("the closing colon converts, and a time stays", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const { handle } = await type("ship it :tada: at 10:30:");
  expect(handle.plainText()).toBe("ship it 🎉 at 10:30:");
});
