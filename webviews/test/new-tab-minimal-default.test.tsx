// New Tab opens on Minimal (Leo 2026-10-20: "only do the composer for the default"), a layout of
// its own beside the others: the composer, which keeps its project strip, and no greeting (Leo
// 2026-10-22: "new tab page let's have no greeting text by default... maybe as toggle but as useful
// toggle"). The toggle (`tabs.newTabWidgets.greeting`) draws a headline that asks what to work on,
// with the project as an inline picker, never a time-of-day greeting. The
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
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import {
  DEFAULT_NEW_TAB_TEMPLATE,
  PAGE_STYLES,
  shownTemplate,
  type ScreenTemplate,
} from "../src/agent-session/acpmux/newtab/templates";
import {
  PAGE_WIDGETS,
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
// 9:30 local time, when the page once said "Good morning".
const MORNING = new Date(2026, 9, 20, 9, 30).getTime();

type RenderOptions = {
  projects?: { cwd: string; label: string }[];
  onAsk?: (...args: unknown[]) => void;
  headlineOff?: boolean;
};

async function render(
  template: ScreenTemplate | undefined,
  widgets: readonly PageWidget[] | undefined,
  startCwd?: string,
  options: RenderOptions = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  await act(async () =>
    root.render(
      <NewTabScreen
        {...(template ? { template, pageWidgets: shownPageWidgets(template, widgets) } : {})}
        now={MORNING}
        snapshot={noChat(manySessions(12))}
        lastAgent="claude"
        cwd="/Users/you/src/atlas"
        {...(startCwd ? { startCwd } : {})}
        projects={options.projects ?? [{ cwd: "/Users/you/src/atlas", label: "atlas" }]}
        loadChatsPage={async () => ({ ready: true, chats: [] })}
        onOpenChat={noop}
        onCreate={noop}
        onAsk={options.onAsk ?? noop}
        {...(options.headlineOff ? { headlineOff: true } : {})}
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
  headline: host.querySelector(".nt-headline-text")?.textContent ?? null,
  stage: host.querySelectorAll(".nt-stage").length,
  projects: host.querySelectorAll(".nt-env").length,
  actions: host.querySelectorAll(".nt-suggest, .nt-create").length,
  chats: host.querySelectorAll(".nt-cards, .nt-all, .nt-closed").length,
  strip: host.querySelectorAll(".acpmux-composer-strip").length,
});

test("Minimal is the default layout and the first dot; no other layout is gone", () => {
  expect(DEFAULT_NEW_TAB_TEMPLATE).toBe("minimal");
  expect(shownTemplate({ layout: "b" })).toBe("minimal");
  expect(PAGE_STYLES).toEqual(["minimal", "cards", "default", "threads", "console", "classic"]);
});

test("by default Minimal is the composer alone", async () => {
  const root = await render("minimal", undefined);
  try {
    expect(parts()).toEqual({
      minimal: true,
      headline: null,
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
    await act(async () => root.unmount());
  }
});

test("an unset NewTabScreen template uses Minimal instead of the old Default stage", async () => {
  const root = await render(undefined, undefined);
  try {
    expect(parts()).toEqual({
      minimal: true,
      headline: null,
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

test("the toggle draws a useful headline: what to work on, with the project as an inline picker", async () => {
  // The host's start folder is the project the composer's strip names, so the headline names it too.
  let root = await render("minimal", ["greeting"], "/Users/you/src/atlas");
  try {
    expect(parts()).toMatchObject({ minimal: true, headline: "What should we work on in atlas?", strip: 1 });
    // The project's name is the picker, inside the question (ProjectChooser inline).
    const picker = host.querySelector<HTMLButtonElement>(".nt-headline-text .acpmux-project-button");
    expect(picker?.textContent).toBe("atlas");
    expect(picker?.getAttribute("aria-haspopup")).toBeTruthy();
    expect(host.textContent).not.toMatch(/Good (morning|afternoon|evening)/);
  } finally {
    await act(async () => root.unmount());
  }
  // No project yet: the question, and Choose project under it.
  root = await render("minimal", ["greeting"]);
  try {
    expect(parts().headline).toBe("What should we work on?");
    expect(host.querySelector(".nt-headline-choose .acpmux-project-button")).not.toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("optional time, warm greeting, stopwatch and quote widgets are independently opt-in", async () => {
  let root = await render("minimal", []);
  try {
    expect(host.querySelector(".nt-extras")).toBeNull();
    expect(host.textContent).not.toMatch(/Good (morning|afternoon|evening)/);
  } finally {
    await act(async () => root.unmount());
  }
  root = await render("minimal", ["clock", "timer", "warmGreeting", "quote"]);
  try {
    expect(host.querySelector(".nt-extra-clock")).not.toBeNull();
    expect(host.querySelector(".nt-extra-timer")).not.toBeNull();
    expect(host.querySelector(".nt-extra-warm")).not.toBeNull();
    expect(host.querySelector(".nt-extra-quote")).not.toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("a project picked in the headline is the folder the composer starts its chat in", async () => {
  const asked: unknown[][] = [];
  const root = await render("minimal", ["greeting"], "/Users/you/src/atlas", {
    projects: [
      { cwd: "/Users/you/src/atlas", label: "atlas" },
      { cwd: "/Users/you/src/manaflow", label: "manaflow" },
    ],
    onAsk: (...args) => asked.push(args),
  });
  try {
    const strip = () => host.querySelector(".acpmux-composer-strip")?.textContent ?? "";
    expect(strip()).toContain("atlas");
    await act(async () => host.querySelector<HTMLButtonElement>(".nt-headline-text .acpmux-project-button")!.click());
    const row = window.document.querySelector<HTMLElement>('[role="option"][aria-label^="manaflow "]');
    expect(row).not.toBeNull();
    await act(async () => {
      row!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
    });
    // The question and the composer's strip both name the pick.
    expect(parts().headline).toBe("What should we work on in manaflow?");
    expect(strip()).toContain("manaflow");
    expect(strip()).not.toContain("atlas");
    // And the prompt is asked there.
    const handle = host.querySelector<MarkdownFieldElement>(".nt-field")!.acpmuxMarkdownField!;
    await act(async () => {
      handle.focus();
      handle.type("what changed?");
    });
    await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Send"]')!.click());
    expect(asked.length).toBe(1);
    expect(asked[0]![2]).toBe("/Users/you/src/manaflow");
  } finally {
    await act(async () => root.unmount());
  }
});

test("Minimal keeps the old greeting's room over the composer, except for a greeting set to false", async () => {
  // The host sends `headlineOff` only for `"greeting": false` saved in cmux.json.
  expect(newTabHost({ newTab: { headlineOff: true } })?.headlineOff).toBe(true);
  expect(newTabHost({ newTab: { headlineOff: false } })?.headlineOff).toBeUndefined();
  expect(newTabHost({ newTab: {} })?.headlineOff).toBeUndefined();
  const slots = () => host.querySelectorAll(".nt-headline-slot").length;
  for (const [widgets, headlineOff, expected] of [
    [undefined, false, 1],
    [[], false, 1],
    [[], true, 0],
    [["greeting"], false, 1],
    // Turned on again in place (edit mode) before the host's next context: the headline has its room.
    [["greeting"], true, 1],
  ] as const) {
    const root = await render("minimal", widgets, undefined, { headlineOff });
    try {
      expect({ widgets, headlineOff, slots: slots() }).toEqual({ widgets, headlineOff, slots: expected });
    } finally {
      await act(async () => root.unmount());
    }
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
    expect(parts()).toMatchObject({ minimal: false, headline: null, stage: 1, projects: 0, actions: 0 });
    expect(parts().chats).toBeGreaterThan(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Minimal with the quick actions alone (the second dot) draws the pills under the composer, no stage", async () => {
  // The second dot on Settings' defaults: the actions on, no headline.
  const root = await render("minimal", ["actions"]);
  try {
    expect(parts()).toMatchObject({ minimal: true, headline: null, stage: 0, projects: 0, chats: 0 });
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
      expect(parts(), template).toMatchObject({ minimal: false, headline: null });
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
  expect([...shownPageWidgets("minimal")]).toEqual([]);
  expect([...shownPageWidgets("minimal", [])]).toEqual([]);
  expect([...shownPageWidgets("cards", ["greeting"])]).toEqual(
    PAGE_WIDGETS.filter(
      (widget) => !["greeting", "weather", "machines", "clock", "timer", "warmGreeting", "quote"].includes(widget),
    ),
  );
});
