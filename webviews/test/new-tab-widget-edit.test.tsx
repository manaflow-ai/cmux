// Minimal's edit mode (Leo 2026-10-20, as editing an iPhone's home screen): right-click the page >
// Edit New Tab, and its widgets wiggle; a drag or Option-Up / Option-Down moves one, its ✕ or
// Delete turns it off, Add Widgets opens App Store Features on New Tab, Done or Escape ends it. The
// page shows its widgets in the order the host sends (`tabs.newTabWidgets.order`), and saves every
// edit through `newTab.editWidgets` (NewTabWidgetEdits.swift writes it as Settings would).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import {
  droppedWidget,
  editedPageWidgets,
  editNewTabWidgets,
  movedWidget,
  parsePageWidgets,
  shownPageWidgets,
  type PageWidget,
  type WidgetEdit,
} from "../src/agent-session/acpmux/newtab/pageWidgets";
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
  "MouseEvent",
  "KeyboardEvent",
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
    MouseEvent: window.MouseEvent,
    KeyboardEvent: window.KeyboardEvent,
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

async function render(
  template: ScreenTemplate,
  widgets: readonly PageWidget[],
  onEditWidgets: ((edit: WidgetEdit) => void) | undefined,
) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  await act(async () =>
    root.render(
      <NewTabScreen
        template={template}
        pageWidgets={shownPageWidgets(template, widgets)}
        {...(onEditWidgets ? { onEditWidgets } : {})}
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
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  return root;
}

/// The stage's widgets, top to bottom.
function stageOrder(): string[] {
  const parts = [...host.querySelectorAll(".nt-env, .nt-suggest, .nt-chats")];
  return parts.map((part) =>
    part.matches(".nt-env") ? "projects" : part.matches(".nt-suggest") ? "actions" : "chats",
  );
}

async function openEditMode() {
  const screen = host.querySelector<HTMLElement>(".nt-screen")!;
  await act(async () =>
    screen.dispatchEvent(
      new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 }),
    ),
  );
  const item = [...window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (row) => row.textContent === "Edit New Tab",
  );
  expect(item).toBeDefined();
  await act(async () => item!.click());
}

const ADD_BUTTON = 'button.nt-edit-button[data-menu="newtab-add-widget"]';
/// The open Add Widgets menu's rows (ui/Menu draws them in a portal, outside the page's root).
const addRows = () => [
  ...window.document.querySelectorAll<HTMLElement>('.nt-edit-add-menu[role="menu"] [role="menuitem"]'),
];
const frame = (widget: PageWidget) => host.querySelector<HTMLElement>(`.nt-widget-frame[data-widget="${widget}"]`);

test("the host's order places the movable widgets; the others keep their places", () => {
  expect(parsePageWidgets(["styleDots", "chats", "greeting", "projects", "chats", "bogus"])).toEqual([
    "greeting",
    "chats",
    "projects",
    "styleDots",
  ]);
  expect(editedPageWidgets(["greeting", "projects", "chats"], { edit: "remove", widget: "projects" })).toEqual([
    "greeting",
    "chats",
  ]);
  expect(
    editedPageWidgets(["greeting", "projects", "chats", "styleDots"], { edit: "order", order: ["chats", "projects"] }),
  ).toEqual(["greeting", "chats", "projects", "styleDots"]);
  expect(editedPageWidgets(undefined, { edit: "remove", widget: "greeting" })).toEqual([]);
  expect(movedWidget(["projects", "actions", "chats"], "chats", -1)).toEqual(["projects", "chats", "actions"]);
  expect(movedWidget(["projects", "actions"], "projects", -1)).toEqual(["projects", "actions"]);
  expect(droppedWidget(["projects", "actions", "chats"], "projects", "chats", true)).toEqual([
    "actions",
    "chats",
    "projects",
  ]);
  expect(droppedWidget(["projects", "actions", "chats"], "chats", "projects", false)).toEqual([
    "chats",
    "projects",
    "actions",
  ]);
});

test("an edit is saved by the host and shown at once", () => {
  const calls: unknown[] = [];
  const shown: WidgetEdit[] = [];
  editNewTabWidgets(
    { edit: "remove", widget: "chats" },
    {
      callNative: async (method, params) => calls.push([method, params]),
      show: (edit) => shown.push(edit),
    },
  );
  expect(calls).toEqual([["newTab.editWidgets", { edit: "remove", widget: "chats" }]]);
  expect(shown).toEqual([{ edit: "remove", widget: "chats" }]);
});

test("Minimal draws its stage in the user's order, with nothing extra out of edit mode", async () => {
  const root = await render("minimal", parsePageWidgets(["greeting", "chats", "actions", "projects"])!, noop);
  try {
    expect(stageOrder()).toEqual(["chats", "actions", "projects"]);
    // Minimal keeps its headline over the stage (the greeting was dropped once a stage widget was on).
    expect(host.querySelector(".nt-stage .nt-headline")).not.toBeNull();
    expect(host.querySelectorAll(".nt-widget-frame, .nt-widget-remove, .nt-edit-bar")).toHaveLength(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("edit mode: ✕ and Delete turn a widget off, Option-arrows move it, Escape ends it", async () => {
  const edits: WidgetEdit[] = [];
  const root = await render("minimal", ["projects", "actions", "chats"], (edit) => edits.push(edit));
  try {
    await openEditMode();
    expect(host.querySelector(".nt-screen")?.hasAttribute("data-editing")).toBe(true);
    expect([...host.querySelectorAll(".nt-widget-frame")].map((node) => node.getAttribute("data-widget"))).toEqual([
      "projects",
      "actions",
      "chats",
    ]);
    // An edited widget takes no clicks of its own: its content is inert.
    expect(frame("projects")?.querySelector(".nt-widget-content")?.hasAttribute("inert")).toBe(true);

    await act(async () => frame("actions")!.querySelector<HTMLButtonElement>(".nt-widget-remove")!.click());
    expect(edits.at(-1)).toEqual({ edit: "remove", widget: "actions" });

    await act(async () =>
      frame("chats")!.dispatchEvent(
        new window.KeyboardEvent("keydown", { key: "ArrowUp", altKey: true, bubbles: true, cancelable: true }),
      ),
    );
    expect(edits.at(-1)).toEqual({ edit: "order", order: ["projects", "chats", "actions"] });

    await act(async () =>
      frame("projects")!.dispatchEvent(
        new window.KeyboardEvent("keydown", { key: "Delete", bubbles: true, cancelable: true }),
      ),
    );
    expect(edits.at(-1)).toEqual({ edit: "remove", widget: "projects" });

    // Add Widgets is a ui/Menu of the widgets (#24631): a row turns its widget on.
    const add = () => host.querySelector<HTMLButtonElement>(ADD_BUTTON)!;
    await act(async () => add().click());
    expect(add().getAttribute("aria-expanded")).toBe("true");
    const projects = addRows().find((row) => row.textContent === "Projects");
    expect(projects).toBeDefined();
    await act(async () => projects!.click());
    expect(edits.at(-1)).toEqual({ edit: "show", widget: "projects" });
    // A pick closes the menu; with it open, Escape closes the menu first and keeps edit mode.
    expect(window.document.querySelector(".nt-edit-add-menu")).toBeNull();
    await act(async () => add().click());
    expect(addRows().length).toBeGreaterThan(0);
    await act(async () =>
      window.document.dispatchEvent(
        new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
      ),
    );
    expect(window.document.querySelector(".nt-edit-add-menu")).toBeNull();
    expect(host.querySelector(".nt-screen")?.hasAttribute("data-editing")).toBe(true);

    await act(async () =>
      window.document.dispatchEvent(
        new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
      ),
    );
    expect(host.querySelector(".nt-screen")?.hasAttribute("data-editing")).toBe(false);
    expect(host.querySelectorAll(".nt-widget-frame")).toHaveLength(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("Add Widgets is a ui/Menu: the arrow keys move along its rows, Enter adds one, Escape hands focus back", async () => {
  const edits: WidgetEdit[] = [];
  const root = await render("minimal", ["projects", "actions", "chats"], (edit) => edits.push(edit));
  const key = (target: EventTarget, name: string) =>
    act(async () => {
      target.dispatchEvent(new window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
    });
  try {
    await openEditMode();
    const add = host.querySelector<HTMLButtonElement>(ADD_BUTTON)!;
    expect(add.getAttribute("aria-haspopup")).toBe("menu");
    await act(async () => add.focus());
    await act(async () => add.click());
    const rows = addRows();
    // Every built-in widget is a row of the menu, the headline first.
    expect(rows).toHaveLength(11);
    expect(rows[0]!.textContent).toBe("Headline");
    expect(rows[1]!.textContent).toBe("Clock");
    const menu = window.document.querySelector<HTMLElement>(".nt-edit-add-menu")!;
    expect(menu.getAttribute("aria-label")).toBe("Add Widgets");
    await key(window.document.activeElement ?? menu, "ArrowDown");
    await key(window.document.activeElement ?? menu, "ArrowDown");
    // Opened from the keyboard, the first row has the keyboard; two arrows go to the third (the timer).
    const active = window.document.activeElement as HTMLElement;
    expect(rows.indexOf(active)).toBe(2);
    await key(active, "Enter");
    expect(edits).toEqual([{ edit: "show", widget: "timer" }]);
    expect(window.document.querySelector(".nt-edit-add-menu")).toBeNull();
    expect(window.document.activeElement).toBe(add);

    // Escape closes the open menu only, and the keyboard is back on Add Widgets.
    await act(async () => add.click());
    expect(addRows().length).toBe(rows.length);
    await key(window.document.activeElement ?? add, "Escape");
    expect(window.document.querySelector(".nt-edit-add-menu")).toBeNull();
    expect(host.querySelector(".nt-screen")?.hasAttribute("data-editing")).toBe(true);
    expect(window.document.activeElement).toBe(add);
  } finally {
    await act(async () => root.unmount());
  }
});

test("only Minimal has an edit mode: the other layouts draw what they always drew", async () => {
  const root = await render("default", ["greeting"], noop);
  try {
    const screen = host.querySelector<HTMLElement>(".nt-screen")!;
    await act(async () =>
      screen.dispatchEvent(
        new window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 40 }),
      ),
    );
    expect(window.document.querySelector('[role="menu"]')).toBeNull();
    expect(stageOrder()).toEqual(["projects", "actions", "chats"]);
  } finally {
    await act(async () => root.unmount());
  }
});
