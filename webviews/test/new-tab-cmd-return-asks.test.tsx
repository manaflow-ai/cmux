// Cmd-Return always asks the agent with the typed text, whatever row leads (cmuxterm-hq lenses review
// new-tab.lens-review-2026-11-05.md finding 1, Nielsen's user control and freedom): when the page
// guesses wrong ("reddit" opens reddit.com, an exact tab name jumps to it) one key goes back to Ask.
// The Ask row shows that keycap.
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

async function render(calls: unknown[][], history: { url: string }[] = []) {
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
    history: [{ url: "about:blank" }, ...history],
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

// The field is the composer's Markdown field (#26567): it is driven through its handle, and keys
// go to its editable element, cancelable as a person's are (the field's own Return sends whatever
// the page's handler did not take with preventDefault).
const handle = () => host.querySelector<MarkdownFieldElement>(".nt-field")!.acpmuxMarkdownField!;

/// Types `text` as the whole prompt, caret at its end; the editable element takes the keys.
async function type(text: string) {
  await act(async () => {
    handle().focus();
    handle().type(text);
  });
  return host.querySelector<HTMLElement>(".nt-field [contenteditable]")!;
}

/// The prompt's text as typed (no Markdown escaping).
const typed = () => handle().agentText(handle().value());

/// Focuses the field and puts the caret `offset` characters in (the end by default).
async function caretAt(offset?: number) {
  await act(async () => {
    handle().focus();
    handle().setCaret(offset ?? handle().plainText().length);
  });
}

const rows = () => [...window.document.querySelectorAll<HTMLElement>('[role="option"]')];
const label = (row: HTMLElement) => row.querySelector(".nt-row-title")?.textContent ?? "";
const press = (field: HTMLElement, init: KeyboardEventInit) =>
  act(async () =>
    field.dispatchEvent(
      new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true, ...init }),
    ),
  );

test('Return opens reddit.com for "reddit"; Cmd-Return asks the agent instead', async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("reddit");
  expect(label(rows()[0]!)).toBe("reddit.com");
  await press(field, { metaKey: true });
  expect(calls).toEqual([["ask", "claude", "reddit", undefined, "claude-opus-5-5"]]);
});

test("Cmd-Return asks even when a row the arrows picked leads", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("reddit-scraper");
  await act(async () =>
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true })),
  );
  await press(field, { metaKey: true });
  expect(calls).toEqual([["ask", "claude", "reddit-scraper", undefined, "claude-opus-5-5"]]);
});

test("the Ask row shows Cmd-Return's keycap when another row leads", async () => {
  await render([]);
  await type("reddit");
  const ask = rows().find((row) => label(row) === "Ask Claude Code")!;
  expect(ask.querySelector(".nt-row-action kbd")?.textContent).toBe("⌘↵");
});
