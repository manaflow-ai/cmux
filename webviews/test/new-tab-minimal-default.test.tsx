// New Tab opens on Minimal (Leo 2026-10-20: "only do the composer for the default"), a layout of
// its own beside the others: a quiet greeting and the composer, which keeps its project strip. The
// project card, the quick actions, the recent chats and the template dots are Minimal's widgets
// (`tabs.newTabWidgets.*`, newtab/pageWidgets.ts), off until the user turns them on. The page has
// no Search | Ask switch (new-tab-auto-action.test.tsx), with or without the widgets. The other
// layouts draw what they always drew.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import { newTabHost } from "../src/agent-session/acpmux/NewTabPage";
import {
  DEFAULT_NEW_TAB_TEMPLATE,
  PAGE_STYLES,
  shownTemplate,
  type ScreenTemplate,
} from "../src/agent-session/acpmux/newtab/templates";
import {
  PAGE_WIDGETS,
  greetingKey,
  parsePageWidgets,
  shownPageWidgets,
  type PageWidget,
} from "../src/agent-session/acpmux/newtab/pageWidgets";

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
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
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
// 9:30 local time: the morning greeting.
const MORNING = new Date(2026, 9, 20, 9, 30).getTime();

async function render(template: ScreenTemplate, widgets: readonly PageWidget[] | undefined) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  await act(async () =>
    root.render(
      <NewTabScreen
        template={template}
        pageWidgets={shownPageWidgets(template, widgets)}
        now={MORNING}
        snapshot={noChat(manySessions(12))}
        lastAgent="claude"
        cwd="/Users/you/src/atlas"
        projects={[{ cwd: "/Users/you/src/atlas", label: "atlas" }]}
        loadChatsPage={async () => ({ ready: true, chats: [] })}
        onOpenChat={noop}
        onCreate={noop}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  return root;
}

const parts = () => ({
  minimal: host.querySelector(".nt-screen")?.hasAttribute("data-minimal") ?? false,
  greeting: host.querySelector(".nt-greeting")?.textContent ?? null,
  stage: host.querySelectorAll(".nt-stage").length,
  projects: host.querySelectorAll(".nt-env").length,
  actions: host.querySelectorAll(".nt-suggest, .nt-create").length,
  chats: host.querySelectorAll(".nt-cards, .nt-all, .nt-closed").length,
  strip: host.querySelectorAll(".acpmux-composer-strip").length,
});

test("Minimal is the default layout and the first dot; no other layout is gone", () => {
  expect(DEFAULT_NEW_TAB_TEMPLATE).toBe("minimal");
  expect(shownTemplate({ layout: "b" })).toBe("minimal");
  expect(PAGE_STYLES).toEqual(["minimal", "cards", "default", "composer", "threads", "console", "classic"]);
});

test("Minimal is the greeting and the composer, with its project strip", async () => {
  const root = await render("minimal", ["greeting"]);
  try {
    expect(parts()).toEqual({
      minimal: true,
      greeting: "Good morning",
      stage: 0,
      projects: 0,
      actions: 0,
      chats: 0,
      strip: 1,
    });
  } finally {
    await act(async () => root.unmount());
  }
});

test("Minimal's widgets turned on take Default's stage around the composer", async () => {
  let root = await render("minimal", [...PAGE_WIDGETS]);
  try {
    expect(parts()).toMatchObject({ minimal: false, stage: 1, projects: 1 });
    expect(parts().actions).toBeGreaterThan(0);
    expect(parts().chats).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
  root = await render("minimal", ["chats"]);
  try {
    expect(parts()).toMatchObject({ minimal: false, greeting: null, stage: 1, projects: 0, actions: 0 });
    expect(parts().chats).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Minimal with the quick actions alone (the second dot) draws the pills under the composer, no stage", async () => {
  const root = await render("minimal", ["greeting", "actions"]);
  try {
    expect(parts()).toMatchObject({ minimal: true, greeting: "Good morning", stage: 0, projects: 0, chats: 0 });
    expect(host.querySelector(".nt-suggest")).toBeNull();
    const pills = [...host.querySelectorAll<HTMLElement>(".nt-create.ui-ghost-row [data-create]")];
    expect(pills.map((pill) => pill.dataset.create)).toEqual(["terminal", "browser", "chat"]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the other layouts ignore Minimal's widgets and draw what they always drew", async () => {
  for (const template of ["cards", "threads", "default"] as const) {
    const root = await render(template, ["greeting"]);
    try {
      expect(parts(), template).toMatchObject({ minimal: false, greeting: null });
      expect(parts().chats, template).toBeGreaterThan(0);
    } finally {
      await act(async () => root.unmount());
    }
  }
});

test("the handshake's pageWidgets: known names in order, Settings' defaults when absent", () => {
  expect(parsePageWidgets(["styleDots", "bogus", "greeting", 3])).toEqual(["greeting", "styleDots"]);
  expect(parsePageWidgets([])).toEqual([]);
  expect(parsePageWidgets(undefined)).toBeUndefined();
  expect(newTabHost({ newTab: { pageWidgets: ["chats"] } })?.pageWidgets).toEqual(["chats"]);
  expect(newTabHost({ newTab: { pageWidgets: [] } })?.pageWidgets).toEqual([]);
  expect(newTabHost({ newTab: {} })?.pageWidgets).toBeUndefined();
  expect([...shownPageWidgets("minimal")]).toEqual(["greeting"]);
  expect([...shownPageWidgets("minimal", [])]).toEqual([]);
  expect([...shownPageWidgets("cards", ["greeting"])]).toEqual(
    PAGE_WIDGETS.filter((widget) => widget !== "greeting" && widget !== "weather" && widget !== "machines"),
  );
});

test("the greeting follows the hour", () => {
  expect([4, 5, 11, 12, 17, 18, 23, 0].map(greetingKey)).toEqual([
    "greeting.evening",
    "greeting.morning",
    "greeting.morning",
    "greeting.afternoon",
    "greeting.afternoon",
    "greeting.evening",
    "greeting.evening",
    "greeting.evening",
  ]);
});
