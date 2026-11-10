// New Tab has no widgets (Lawrence 2026-11-09: "remove widgets completely"). Minimal is the composer
// alone, whatever an old host or an old cmux-next.json (`tabs.newTabWidgets.*`, now retired) still
// sends: no headline, clock, stopwatch, warm greeting, quote, weather, machines, cards or edit mode.
// The other layouts draw their own parts, with no widget toggles.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import { newTabHost } from "../src/agent-session/acpmux/newTabModel";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import type { ScreenTemplate } from "../src/agent-session/acpmux/newtab/templates";

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

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
const MORNING = new Date(2026, 9, 20, 9, 30).getTime();
const OLD_WIDGETS = [
  "greeting",
  "projects",
  "actions",
  "chats",
  "styleDots",
  "weather",
  "machines",
  "clock",
  "timer",
  "warmGreeting",
  "quote",
];
const OLD_WEATHER = {
  place: "Berlin",
  temperature: 21,
  high: 24,
  low: 12,
  code: 0,
  unit: "celsius",
  readAt: MORNING,
};

/// What an older host put in the page's props for the widgets; the page must ignore all of it.
const legacyWidgetProps = (): Record<string, unknown> => ({
  widgets: true,
  pageWidgets: new Set(OLD_WIDGETS),
  headlineOff: false,
  weather: OLD_WEATHER,
  onEditWidgets: noop,
});

async function render(template: ScreenTemplate) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  await act(async () =>
    root.render(
      <NewTabScreen
        {...(legacyWidgetProps() as object)}
        template={template}
        now={MORNING}
        snapshot={noChat(manySessions(12))}
        lastAgent="claude"
        cwd="/Users/you/src/atlas"
        projects={[{ cwd: "/Users/you/src/atlas", label: "atlas" }]}
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

/// Every widget's or edit mode's mark on the page.
const WIDGET_UI = [
  ".nt-headline",
  ".nt-extras",
  ".nt-extra-clock",
  ".nt-extra-timer",
  ".nt-extra-warm",
  ".nt-extra-quote",
  ".nt-ambient",
  ".nt-widgets",
  ".nt-widget-frame",
  ".nt-edit-bar",
  "[data-editing]",
].join(", ");

test("the handshake carries no widget fields, whatever an older host sends", () => {
  const page = newTabHost({
    newTab: { pageWidgets: OLD_WIDGETS, weather: OLD_WEATHER, widgets: true, headlineOff: true },
  }) as Record<string, unknown> | undefined;
  expect(page).toBeDefined();
  for (const field of ["pageWidgets", "weather", "widgets", "headlineOff"]) expect(page![field]).toBeUndefined();
});

test("Minimal is the composer alone, with no widget and no edit mode", async () => {
  const root = await render("minimal");
  try {
    const screen = host.querySelector<HTMLElement>(".nt-screen")!;
    expect(screen.hasAttribute("data-minimal")).toBe(true);
    expect(host.querySelector(".nt-field")).not.toBeNull();
    expect(host.querySelectorAll(".acpmux-composer-strip").length).toBe(1);
    expect(host.querySelectorAll(WIDGET_UI).length).toBe(0);
    expect(host.querySelectorAll(".nt-stage, .nt-env, .nt-suggest, .nt-create, .nt-cards, .nt-all").length).toBe(0);
    expect(host.textContent).not.toMatch(/Good (morning|afternoon|evening)|Stopwatch|What should we work on/);
    // A right-click offers no Edit New Tab.
    await act(async () =>
      screen.dispatchEvent(
        new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 }),
      ),
    );
    const items = [...window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')];
    expect(items.map((item) => item.textContent)).not.toContain("Edit New Tab");
  } finally {
    await act(async () => root.unmount());
  }
});

test("the other layouts draw their own parts and no widget", async () => {
  const root = await render("default");
  try {
    expect(host.querySelectorAll(".nt-stage").length).toBe(1);
    expect(host.querySelectorAll(".nt-env").length).toBe(1);
    expect(host.querySelectorAll(".nt-cards, .nt-all, .nt-closed").length).toBeGreaterThan(0);
    expect(host.querySelectorAll(WIDGET_UI).length).toBe(0);
  } finally {
    await act(async () => root.unmount());
  }
});
