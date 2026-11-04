// The New Tab field is an omnibar (Leo 2026-10-12): typing "reddit" showed nothing, the rows that
// did show pushed the page down, and blank browser tabs were offered as "about:blank workspace-N".
// Now the rows float in a popover under the composer: URL completions from visited pages and top
// sites, open tabs and workspaces, "Ask <agent>" and "Search the web for …", the top row highlighted
// and taken by Return. Leo 2026-10-24 ("Search the web. Do you really want that first?"): a
// completion leads only for a site's whole name ("reddit") or a host ("reddit.c"); a partial word
// asks the agent.
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

test('typing "reddit" offers reddit.com first, highlighted, and Return opens it in a browser tab', async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("reddit");

  const shown = rows();
  expect(shown.length).toBeGreaterThan(0);
  expect(label(shown[0]!)).toBe("reddit.com");
  expect(shown[0]!.getAttribute("aria-selected")).toBe("true");
  const titles = shown.map(label);
  expect(titles).toContain("Search the web for reddit");
  expect(titles).toContain("Ask Claude Code");
  expect(titles).toContain("reddit-scraper");
  expect(titles).toContain("Reddit docs");
  expect(titles.some((title) => title.includes("about:blank"))).toBe(false);

  await act(async () =>
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
  );
  expect(calls).toEqual([["open", "https://reddit.com"]]);
});

test("Right accepts the inline URL completion without opening it", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("reddit.c");
  await caretAt();
  await act(async () =>
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true })),
  );
  expect(typed()).toBe("reddit.com");
  expect(calls).toEqual([]);
});

test("a partial word asks first: the completion is one row down and Right leaves the text", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("reddi");
  expect(label(rows()[0]!)).toBe("Ask Claude Code");
  expect(rows().map(label)).toContain("reddit.com");
  await caretAt();
  await act(async () =>
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true })),
  );
  expect(typed()).toBe("reddi");
  expect(calls).toEqual([]);
});

test("End accepts the inline URL completion and Tab only advances a keyboard-highlighted row", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("reddit");
  await caretAt();
  await act(async () =>
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "End", bubbles: true, cancelable: true })),
  );
  expect(typed()).toBe("reddit.com");

  // A fresh query has multiple rows; once Down highlights one, Tab moves the highlight and never submits.
  await type("reddi");
  await caretAt();
  await act(async () =>
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true })),
  );
  const before = rows().findIndex((row) => row.getAttribute("aria-selected") === "true");
  const tab = new window.KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
  await act(async () => field.dispatchEvent(tab));
  expect(tab.defaultPrevented).toBe(true);
  const after = rows().findIndex((row) => row.getAttribute("aria-selected") === "true");
  expect(after).toBe((before + 1) % rows().length);
  expect(calls).toEqual([]);
});

// With no Search | Ask switch (Leo 2026-10-20), Tab steps the suggestions as in Chrome's omnibox,
// from Return's row; Shift-Tab is still the browser's, so the keyboard can leave the field.
test("Tab with suggestions showing steps from Return's row", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("why is the reddit scraper slow");
  await caretAt();
  expect(rows().length).toBeGreaterThan(0);
  const tab = new window.KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
  await act(async () => field.dispatchEvent(tab));
  expect(tab.defaultPrevented).toBe(true);
  expect(rows()[0]?.getAttribute("data-type")).toBe("ask");
  expect(rows().findIndex((row) => row.getAttribute("aria-selected") === "true")).toBe(1);
  const back = new window.KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true, cancelable: true });
  await act(async () => field.dispatchEvent(back));
  expect(back.defaultPrevented).toBe(false);
  expect(calls).toEqual([]);
});

// A visited page completes inline like Chrome's omnibox: Right fills the field and opens nothing.
test("Right inline-accepts a visited-page (history) row without opening it", async () => {
  const calls: unknown[][] = [];
  await render(calls, [{ url: "https://zulip.example.com/" }]);
  const field = await type("zulip");
  expect(rows()[0]?.getAttribute("data-type")).toBe("history");
  await caretAt();
  await act(async () =>
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true })),
  );
  expect(typed()).toBe("zulip.example.com");
  expect(calls).toEqual([]);
});

test("the rows float in a popover over the page, not in the page's flow", async () => {
  await render([]);
  const field = await type("reddit");
  const popover = window.document.querySelector('[role="listbox"]')!;
  expect(popover.closest(".nt-popover")).not.toBeNull();
  // Portaled out of the page to the popup layer, so no section moves or covers it.
  expect(popover.closest(".nt-screen")).toBeNull();
  expect(popover.closest(".ui-positioner")).not.toBeNull();
  expect(field.getAttribute("aria-controls")).toBe(popover.id);
});

test("a prompt's top row asks the agent, with a web search under it", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("why is the reddit scraper slow");
  const shown = rows();
  expect(label(shown[0]!)).toBe("Ask Claude Code");
  expect(shown[0]!.getAttribute("aria-selected")).toBe("true");
  expect(shown.map(label)).toContain("Search the web for why is the reddit scraper slow");
  await act(async () =>
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
  );
  // On the model the chip names (cx-sljrg).
  expect(calls).toEqual([["ask", "claude", "why is the reddit scraper slow", undefined, "claude-opus-5-5"]]);
});

// Lucas 2026-10-26: the arrows wrapped through the rows and never came back to the chat field.
// Down on the last row still wraps to the top row, but Up on the top row returns to the field (no
// row highlighted), and Return there sends the prompt.
test("Down on the last row wraps to the top; Up on the top row comes back to the field", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("why is the reddit scraper slow");
  const highlighted = () => rows().findIndex((row) => row.getAttribute("aria-selected") === "true");
  const press = (key: string) =>
    act(async () => field.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true })));
  const count = rows().length;
  expect(count).toBeGreaterThan(1);
  expect(highlighted()).toBe(0);

  for (let step = 1; step < count; step += 1) await press("ArrowDown");
  expect(highlighted()).toBe(count - 1);
  await press("ArrowDown");
  expect(highlighted()).toBe(0);
  await press("ArrowUp");
  expect(highlighted()).toBe(-1);
  await press("ArrowUp");
  expect(highlighted()).toBe(count - 1);
  for (let step = 1; step < count; step += 1) await press("ArrowUp");
  expect(highlighted()).toBe(0);
  await press("ArrowUp");
  expect(highlighted()).toBe(-1);

  await press("Enter");
  expect(calls).toEqual([["ask", "claude", "why is the reddit scraper slow", undefined, "claude-opus-5-5"]]);
});

// Lucas 2026-10-26: in a prompt of several lines ↑ cycled the rows, so the caret could not go up a
// line. The top row stays selected while typing (the list has the arrows), ↑ from it goes back to the
// text, and in the text ↑ and ↓ move the caret while there is a line to go to, as in the chat's
// composer; ← and → in the list go back to the text and move the caret.
test("in the text Up and Down move the caret between lines; in the list they step the rows", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("first line\nsecond line");
  const highlighted = () => rows().findIndex((row) => row.getAttribute("aria-selected") === "true");
  const press = async (key: string) => {
    const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
    await act(async () => field.dispatchEvent(event));
    return event.defaultPrevented;
  };
  const count = rows().length;
  expect(count).toBeGreaterThan(1);
  expect(highlighted()).toBe(0);

  await caretAt(); // the second line
  expect(await press("ArrowDown")).toBe(true); // the list: the next row
  expect(highlighted()).toBe(1);
  expect(await press("ArrowUp")).toBe(true);
  expect(await press("ArrowUp")).toBe(true); // the top row: back to the text
  expect(highlighted()).toBe(-1);

  expect(await press("ArrowUp")).toBe(false); // the text: the caret goes up a line
  expect(highlighted()).toBe(-1);
  await caretAt(3); // the first line
  expect(await press("ArrowDown")).toBe(false); // the caret goes down a line
  expect(await press("ArrowUp")).toBe(true); // the first line: into the rows, at the last
  expect(highlighted()).toBe(count - 1);

  expect(await press("ArrowLeft")).toBe(false); // the list: back to the text, the caret moves
  expect(highlighted()).toBe(-1);
  await press("Enter");
  expect(calls).toEqual([["ask", "claude", "first line\nsecond line", undefined, "claude-opus-5-5"]]);
});

// Review of https://github.com/manaflow-ai/cmux/pull/25222: ← to fix a typo left the list, and Return on an address then did nothing (no
// row, and an address is no prompt). The top row typing selects keeps ← and → for the caret, and
// with no row selected (↑ from the top row) Return still opens the address.
test("an address keeps Return opening it after Left, and after Up from the top row", async () => {
  const highlighted = () => rows().findIndex((row) => row.getAttribute("aria-selected") === "true");
  for (const key of ["ArrowLeft", "ArrowUp"]) {
    const calls: unknown[][] = [];
    await render(calls);
    const field = await type("reddit.com");
    await act(async () =>
      field.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true })),
    );
    expect(highlighted()).toBe(key === "ArrowLeft" ? 0 : -1);
    await act(async () =>
      field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
    );
    expect(calls).toEqual([["open", "https://reddit.com"]]);
  }
});

// Leo 10-13: after typing, a click outside the composer left the suggestions open. A press outside
// and Escape close them and keep the typed text; a second Escape leaves the field.
function pressOutside() {
  const target = window.document.body;
  const Pointer = (window as unknown as { PointerEvent?: typeof window.MouseEvent }).PointerEvent ?? window.MouseEvent;
  for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
    const event = type.startsWith("pointer")
      ? new Pointer(type, { bubbles: true, cancelable: true, button: 0 })
      : new window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0 });
    target.dispatchEvent(event);
  }
}

test("a press outside closes the suggestions and keeps the text; pressing the field opens them again", async () => {
  await render([]);
  const field = await type("reddit");
  await act(async () => handle().focus());
  expect(rows().length).toBeGreaterThan(0);
  await act(async () => pressOutside());
  expect(rows()).toHaveLength(0);
  expect(typed()).toBe("reddit");
  await act(async () => field.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 })));
  expect(rows().length).toBeGreaterThan(0);
});

test("Escape closes the suggestions and keeps the text; a second Escape leaves the field", async () => {
  await render([]);
  const field = await type("reddit");
  await act(async () => handle().focus());
  const escape = () =>
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  await act(async () => escape());
  expect(rows()).toHaveLength(0);
  expect(typed()).toBe("reddit");
  expect(window.document.activeElement).toBe(field);
  await act(async () => escape());
  expect(typed()).toBe("reddit");
  expect(window.document.activeElement).not.toBe(field);
});

test("Return after Escape still takes the top row: reddit opens reddit.com", async () => {
  const calls: unknown[][] = [];
  await render(calls);
  const field = await type("reddit");
  await act(async () => handle().focus());
  const key = (name: string) =>
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
  await act(async () => key("Escape"));
  expect(rows()).toHaveLength(0);
  await act(async () => key("Enter"));
  expect(calls).toEqual([["open", "https://reddit.com"]]);
});
