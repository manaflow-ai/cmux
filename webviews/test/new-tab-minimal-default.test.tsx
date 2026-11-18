// New Tab opens on Minimal (Leo 2026-10-20: "only do the composer for the default"), a layout of
// its own beside the others: the composer and create buttons, with no greeting (Leo
// 2026-10-22) and no widgets (Lawrence 2026-11-09: "remove widgets completely",
// new-tab-no-widgets.test.tsx). The page has no Search | Ask switch (new-tab-auto-action.test.tsx).
// The page draws Minimal and nothing else: Cards, Default, Threads and Console moved to looks
// (plans/cmux-next/new-tab-templates.md), and Terminal draws Minimal too.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { DEFAULT_NEW_TAB_TEMPLATE, PAGE_STYLES, shownTemplate } from "../src/agent-session/acpmux/newtab/templates";
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
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const noop = () => {};
// 9:30 local time, when the page once said "Good morning" (the clock is the page's own).
const MORNING = new Date(2026, 9, 20, 9, 30);

async function render() {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  await act(async () =>
    root.render(
      <NewTabScreen
        snapshot={noChat(manySessions(12))}
        lastAgent="claude"
        cwd="/Users/you/src/atlas"
        projects={[{ cwd: "/Users/you/src/atlas", label: "atlas" }]}
        onCreate={noop}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
      />,
    ),
  );
  return root;
}

const parts = () => ({
  minimal: host.querySelector(".nt-screen")?.hasAttribute("data-minimal") ?? false,
  stage: host.querySelectorAll(".nt-stage").length,
  projects: host.querySelectorAll(".nt-env").length,
  actions: host.querySelectorAll(".nt-suggest, .nt-create").length,
  chats: host.querySelectorAll(".nt-cards, .nt-all, .nt-closed").length,
  strip: host.querySelectorAll(".acpmux-composer-strip").length,
});

test("Minimal is the default layout and the first dot", () => {
  expect(DEFAULT_NEW_TAB_TEMPLATE).toBe("minimal");
  expect(shownTemplate({ layout: "b" })).toBe("minimal");
  expect(PAGE_STYLES).toEqual(["minimal", "classic"]);
});

test("by default Minimal shows the composer without fixed create buttons", async () => {
  const realNow = Date.now;
  Date.now = () => MORNING.getTime();
  const root = await render();
  try {
    expect(parts()).toEqual({
      minimal: true,
      stage: 0,
      projects: 0,
      actions: 0,
      chats: 0,
      strip: 1,
    });
    // No time-of-day greeting.
    expect(host.querySelector(".nt-greeting")).toBeNull();
    expect(host.textContent).not.toMatch(/Good (morning|afternoon|evening)/);
  } finally {
    Date.now = realNow;
    await act(async () => root.unmount());
  }
});

test("Minimal keeps the old greeting's room over the composer, empty", async () => {
  const root = await render();
  try {
    expect(host.querySelectorAll(".nt-composer-room").length).toBe(1);
    expect(host.querySelector(".nt-composer-room")?.childElementCount).toBe(0);
  } finally {
    await act(async () => root.unmount());
  }
});
