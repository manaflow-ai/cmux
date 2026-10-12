// The New Tab field is an omnibar (Leo 2026-10-12): typing "reddit" showed nothing, the rows that
// did show pushed the page down, and blank browser tabs were offered as "about:blank workspace-N".
// Now the rows float in a popover under the composer: URL completions from visited pages and top
// sites, open tabs and workspaces, "Search the web for …" and "Ask <agent>", the top row highlighted
// and taken by Return.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { EMPTY_OMNIBAR } from "../src/agent-session/acpmux/omnibar";

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
  const field = host.querySelector<HTMLInputElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(field, text);
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  return field;
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

  await act(async () => field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  expect(calls).toEqual([["open", "https://reddit.com"]]);
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
  await act(async () => field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
  expect(calls).toEqual([["ask", "claude", "why is the reddit scraper slow", undefined]]);
});
