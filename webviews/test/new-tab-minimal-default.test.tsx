// The New Tab page is minimal by default (Leo 2026-10-20: "only do the composer for the default"):
// a quiet greeting and the composer, the project strip in the composer's bottom row. The project
// card, the quick actions, the recent chats, the Search | Ask switch and the template dots are
// widgets (`tabs.newTabWidgets.*`, newtab/pageWidgets.ts), off until the user turns them on; Tab
// still switches Search and Ask without the switch.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import { newTabHost } from "../src/agent-session/acpmux/NewTabPage";
import {
  PAGE_WIDGETS,
  greetingKey,
  pageWidgetSet,
  parsePageWidgets,
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

async function render(template: "default" | "cards" | "threads", widgets: readonly PageWidget[] | undefined) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  await act(async () =>
    root.render(
      <NewTabScreen
        template={template}
        pageWidgets={pageWidgetSet(widgets)}
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
  modeSwitch: host.querySelectorAll(".nt-mode-track").length,
  stripInBox: host.querySelectorAll(".nt-box .nt-bar .acpmux-composer-strip").length,
});

test("the default page is the greeting and the composer, the project strip in its bottom row", async () => {
  const root = await render("default", ["greeting"]);
  try {
    expect(parts()).toEqual({
      minimal: true,
      greeting: "Good morning",
      stage: 0,
      projects: 0,
      actions: 0,
      chats: 0,
      modeSwitch: 0,
      stripInBox: 1,
    });
    // Without the switch Tab still flips Search | Ask: the placeholder says which, and a screen
    // reader still hears the hint the field points at.
    const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
    expect(field.placeholder).toBe("Ask anything or type a URL");
    expect(host.querySelector(`#${field.getAttribute("aria-describedby")}`)?.textContent).toBe("Tab to switch");
    await act(async () => {
      field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true }));
    });
    expect(field.placeholder).toBe("Search the web or type a URL");
  } finally {
    await act(async () => root.unmount());
  }
});

test("each widget turned on comes back; every widget on is the page as it was", async () => {
  let root = await render("default", [...PAGE_WIDGETS]);
  try {
    expect(parts()).toMatchObject({ minimal: false, stage: 1, projects: 1, modeSwitch: 1, stripInBox: 0 });
    expect(parts().actions).toBeGreaterThan(0);
    expect(parts().chats).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
  root = await render("threads", ["chats"]);
  try {
    expect(parts()).toMatchObject({ minimal: false, greeting: null, stage: 0, actions: 0, modeSwitch: 0 });
    expect(parts().chats).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
  // A host that sends no list (from before the widgets) shows every one.
  root = await render("cards", undefined);
  try {
    expect(parts()).toMatchObject({ minimal: false, modeSwitch: 1 });
    expect(parts().chats).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the handshake's pageWidgets: known names in order, nothing when absent", () => {
  expect(parsePageWidgets(["styleDots", "bogus", "greeting", 3])).toEqual(["greeting", "styleDots"]);
  expect(parsePageWidgets([])).toEqual([]);
  expect(parsePageWidgets(undefined)).toBeUndefined();
  expect(newTabHost({ newTab: { pageWidgets: ["chats"] } })?.pageWidgets).toEqual(["chats"]);
  expect(newTabHost({ newTab: { pageWidgets: [] } })?.pageWidgets).toEqual([]);
  expect(newTabHost({ newTab: {} })?.pageWidgets).toBeUndefined();
  expect([...pageWidgetSet(undefined)]).toEqual([...PAGE_WIDGETS]);
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
