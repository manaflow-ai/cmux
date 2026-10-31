// The New Tab page's three dots (Leo 2026-10-23: "1 CLAUDE MINIMAL / 2 CLAUDE MINIMAL + NEW
// TAB/TERMINAL/WHATEVER / 3 CODEX MINIMAL"; newtab/tabDots.ts). A dot keeps no state of its own: it
// is the composer's look and Minimal's quick actions widget. Codex's look is the third dot, Claude's
// with the actions the second, else the first. A pick sets the look and turns the actions on or off
// through the edit mode's `newTab.editWidgets`, shown in place at once. Arrow keys across the three
// are the browser's (test/composer-look-dots.test.ts drives them in Chromium).
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { setComposerLook } from "../src/agent-session/acpmux/composerLook";
import {
  editedPageWidgets,
  shownPageWidgets,
  withWidgetEdit,
  type PageWidget,
  type WidgetEdit,
} from "../src/agent-session/acpmux/newtab/pageWidgets";
import { translateNewTab } from "../src/agent-session/acpmux/newtab/strings";
import { DOT_STATES, NEW_TAB_DOTS, dotName, pickDot, shownDot } from "../src/agent-session/acpmux/newtab/tabDots";

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
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "http://localhost/" })
    .window;
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
    localStorage: window.localStorage,
  });
  host = window.document.getElementById("root")!;
});

beforeEach(() => setComposerLook("claude"));

afterAll(() => {
  // The look is module state: leave the default for the files after this one.
  setComposerLook("claude");
  window.localStorage.clear();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const storedLook = () => window.localStorage.getItem("cmux.composer.look");

test("the dot shown comes from the look and the actions widget", () => {
  expect(NEW_TAB_DOTS).toEqual(["claude", "claudeActions", "codex"]);
  expect(shownDot("claude", false)).toBe("claude");
  expect(shownDot("claude", true)).toBe("claudeActions");
  expect(shownDot("codex", false)).toBe("codex");
  // Codex's look with the actions is not a dot yet ("2 AND 3 MAYBE SWITCHABLE"): the third shows.
  expect(shownDot("codex", true)).toBe("codex");
  // Every dot's own state shows that dot.
  for (const dot of NEW_TAB_DOTS) expect(shownDot(DOT_STATES[dot].look, DOT_STATES[dot].actions)).toBe(dot);
});

test("the dots' names: Claude Minimal, Claude Minimal + Quick Actions, Codex Minimal", () => {
  const nt = (key: Parameters<typeof translateNewTab>[0]) => translateNewTab(key, {}, "en");
  expect(NEW_TAB_DOTS.map((dot) => dotName(dot, nt))).toEqual([
    "Claude Minimal",
    "Claude Minimal + Quick Actions",
    "Codex Minimal",
  ]);
});

test("a pick sets the look and turns the actions on or off only when they differ", () => {
  const calls: [string, unknown][] = [];
  const shown: WidgetEdit[] = [];
  const deps = (actions: boolean) => ({
    actions,
    callNative: async (method: string, params?: unknown) => void calls.push([method, params]),
    show: (edit: WidgetEdit) => void shown.push(edit),
  });

  pickDot("claudeActions", deps(false));
  expect(storedLook()).toBe("claude");
  expect(calls).toEqual([["newTab.editWidgets", { edit: "show", widget: "actions" }]]);
  expect(shown).toEqual([{ edit: "show", widget: "actions" }]);

  pickDot("codex", deps(true));
  expect(storedLook()).toBe("codex");
  expect(calls.at(-1)).toEqual(["newTab.editWidgets", { edit: "remove", widget: "actions" }]);

  pickDot("claude", deps(false));
  expect(storedLook()).toBe("claude");
  // The actions were already off: no edit.
  expect(calls).toHaveLength(2);

  pickDot("claude", deps(true));
  expect(calls.at(-1)).toEqual(["newTab.editWidgets", { edit: "remove", widget: "actions" }]);
  expect(calls).toHaveLength(3);
});

test("a shown widget joins the page's list in its place; a shown one stays once", () => {
  // No list is Settings' defaults: nothing on Minimal (no headline, Leo 2026-10-22).
  expect(editedPageWidgets(undefined, { edit: "show", widget: "actions" })).toEqual(["actions"]);
  expect(editedPageWidgets(["greeting", "chats"], { edit: "show", widget: "actions" })).toEqual([
    "greeting",
    "chats",
    "actions",
  ]);
  expect(editedPageWidgets(["greeting", "actions"], { edit: "show", widget: "actions" })).toEqual([
    "greeting",
    "actions",
  ]);
  expect(editedPageWidgets(["greeting", "actions"], { edit: "remove", widget: "actions" })).toEqual(["greeting"]);
});

async function renderDots(actions: boolean, onEdit: (edit: WidgetEdit) => void): Promise<Root> {
  const { createRoot } = await import("react-dom/client");
  const { PageDots } = await import("../src/agent-session/acpmux/newtab/PageDots");
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <PageDots
        template="minimal"
        styleDots={false}
        actions={actions}
        callNative={async () => undefined}
        show={() => {}}
        showWidgets={onEdit}
        onCancel={() => {}}
      />,
    ),
  );
  return root;
}

const radios = () => [...host.querySelectorAll<HTMLInputElement>(".nt-style input[type=radio]")];

test("the page draws three dots, the derived one checked, and a click on each picks it", async () => {
  const edits: WidgetEdit[] = [];
  let root = await renderDots(false, (edit) => edits.push(edit));
  try {
    expect(radios().map((radio) => [radio.value, radio.getAttribute("aria-label"), radio.checked])).toEqual([
      ["claude", "Claude Minimal", true],
      ["claudeActions", "Claude Minimal + Quick Actions", false],
      ["codex", "Codex Minimal", false],
    ]);
    await act(async () => radios()[1]!.click());
    expect(edits).toEqual([{ edit: "show", widget: "actions" }]);
    expect(storedLook()).toBe("claude");
  } finally {
    await act(async () => root.unmount());
  }
  // The host's widgets now say the actions are on: the second dot is checked.
  root = await renderDots(true, (edit) => edits.push(edit));
  try {
    expect(radios().find((radio) => radio.checked)?.value).toBe("claudeActions");
    await act(async () => radios()[2]!.click());
    expect(storedLook()).toBe("codex");
    expect(edits.at(-1)).toEqual({ edit: "remove", widget: "actions" });
    expect(radios().find((radio) => radio.checked)?.value).toBe("codex");
  } finally {
    await act(async () => root.unmount());
  }
});

// The dots draw on every page style, and the quick actions are Minimal's widget
// (`tabs.newTabWidgets.actions`). A pick on Default or Cards edits only that one widget of Minimal's
// list: the style on screen keeps everything it draws, and Minimal keeps its other widgets, whether
// the host sent the list or not (App.tsx's PageDots wiring, pageWidgets.ts withWidgetEdit).
async function renderPage(template: "default" | "cards", pageWidgets: PageWidget[] | undefined) {
  const { createRoot } = await import("react-dom/client");
  const { useState } = await import("react");
  const { PageDots } = await import("../src/agent-session/acpmux/newtab/PageDots");
  const state: { page: { pageWidgets?: PageWidget[] } } = { page: pageWidgets ? { pageWidgets } : {} };
  function Page() {
    const [page, setPage] = useState(state.page);
    state.page = page;
    return (
      <PageDots
        template={template}
        styleDots={shownPageWidgets(template, page.pageWidgets).has("styleDots")}
        actions={shownPageWidgets("minimal", page.pageWidgets).has("actions")}
        callNative={async () => undefined}
        show={() => {}}
        showWidgets={(edit) => setPage((current) => withWidgetEdit(current, edit))}
        onCancel={() => {}}
      />
    );
  }
  const root = createRoot(host);
  await act(async () => root.render(<Page />));
  return { root, state };
}

for (const template of ["default", "cards"] as const) {
  for (const sent of [undefined, ["greeting", "projects", "chats", "styleDots"] as PageWidget[]]) {
    test(`on ${template} (${sent ? "the host's list" : "no list"}), each dot keeps the page's other widgets`, async () => {
      const { root, state } = await renderPage(template, sent);
      try {
        const others = (sent ?? []).filter((widget) => widget !== "actions");
        for (const [index, dot] of [
          [1, "claudeActions"],
          [0, "claude"],
          [1, "claudeActions"],
          [2, "codex"],
        ] as const) {
          await act(async () => radios()[index]!.click());
          expect(radios().find((radio) => radio.checked)?.value).toBe(dot);
          // The style on screen still draws all it drew, its style dots too.
          expect([...shownPageWidgets(template, state.page.pageWidgets)]).toEqual([
            "projects",
            "actions",
            "chats",
            "styleDots",
          ]);
          expect(host.querySelectorAll(".nt-page-dots .nt-style").length).toBe(2);
          // Minimal keeps every other widget; only the actions follow the dot.
          const minimal = shownPageWidgets("minimal", state.page.pageWidgets);
          for (const widget of others) expect(minimal.has(widget)).toBe(true);
          expect(minimal.has("actions")).toBe(DOT_STATES[dot].actions);
        }
      } finally {
        await act(async () => root.unmount());
      }
    });
  }
}
