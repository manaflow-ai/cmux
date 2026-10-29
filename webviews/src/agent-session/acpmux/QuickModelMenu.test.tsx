// The compact model menu on the New Tab page (newTabComposer.ts): no 1 to 9 key hints, and More models is a row that shows the tab's other models in place
// (not a submenu), keeps the menu open, and leaves keyboard focus in the menu as the rail changes.
import { afterEach, expect, test } from "bun:test";
import React, { act, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { OnNewTab } from "./newTabComposer";
import type { QuickFamily, QuickSearchField } from "./QuickModelMenu";

let QuickModelMenu: typeof import("./QuickModelMenu").QuickModelMenu;
const loadQuickModelMenu = async () => {
  QuickModelMenu ??= (await import("./QuickModelMenu")).QuickModelMenu;
};

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

const family = (id: string, name: string): QuickFamily => ({
  id,
  name,
  models: ["a", "b", "c"].map((model) => ({
    id: `${id}-${model}`,
    name: `${name} ${model}`,
    family: id,
  })),
  more: ["x", "y"].map((model) => ({
    id: `${id}-${model}`,
    name: `${name} old ${model}`,
    family: id,
  })),
});

type HarnessOptions = { onAddHarness?: () => void; noMore?: boolean; searchField?: QuickSearchField };
function Harness({ newTab, onAddHarness, noMore, searchField }: { newTab: boolean } & HarnessOptions) {
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement | null>(null);
  const [fast, setFast] = useState(false);
  return (
    <OnNewTab.Provider value={newTab}>
      <QuickModelMenu
        open={open}
        onOpenChange={setOpen}
        trigger={trigger}
        chip={{ "data-menu": "model", label: "Model", title: "Model" }}
        menu={{
          ...(searchField ? { searchField, search: { find: () => [], pick() {} } } : {}),
          models: [],
          current: "claude-a",
          onModel() {},
          fast: { checked: fast, onChange: setFast },
          families: {
            list: [family("claude", "Claude"), family("codex", "Codex")].map((entry) =>
              noMore ? { ...entry, more: [] } : entry,
            ),
            current: "claude",
            onPick() {},
            onAddHarness,
          },
        }}
        onMore={() => {}}
      >
        Model
      </QuickModelMenu>
    </OnNewTab.Provider>
  );
}

async function openMenu(newTab: boolean, options: HarnessOptions = {}) {
  const container = installDom();
  await loadQuickModelMenu();
  await act(async () => {
    root = createRoot(container);
    root.render(<Harness newTab={newTab} {...options} />);
  });
  await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
  await settle();
}

const list = () => document.querySelector<HTMLElement>(".acpmux-quick-list")!;
const labels = (scope: ParentNode) => [...scope.querySelectorAll(".acpmux-menu-label")].map((node) => node.textContent);
const disclosure = () => document.querySelector<HTMLElement>(".acpmux-quick-disclosure");

test("a chat's menu keeps its key hints and More models submenu", async () => {
  await openMenu(false);
  expect(list().querySelectorAll(".ui-menu-shortcut").length).toBeGreaterThan(0);
  expect(disclosure()).toBeNull();
});

test("on New Tab the menu has no key hints", async () => {
  await openMenu(true);
  expect(list().querySelectorAll(".ui-menu-shortcut").length).toBe(0);
});

test("on New Tab More models shows the tab's other models in place and keeps the menu open", async () => {
  await openMenu(true);
  const row = disclosure()!;
  expect(row.getAttribute("aria-expanded")).toBe("false");
  expect(labels(list())).not.toContain("Claude old x");
  await act(async () => row.click());
  await settle();
  expect(disclosure()?.getAttribute("aria-expanded")).toBe("true");
  const shown = document.querySelector<HTMLElement>(".acpmux-quick-list .acpmux-quick-more-list")!;
  expect(labels(shown)).toEqual(["Claude old x", "Claude old y"]);
  await act(async () => disclosure()!.click());
  await settle();
  expect(disclosure()?.getAttribute("aria-expanded")).toBe("false");
  expect(document.querySelector(".acpmux-quick-list .acpmux-quick-more-list")).toBeNull();
});

test("a rail switch from a shown More models row keeps keyboard focus in the menu", async () => {
  await openMenu(true);
  await act(async () => disclosure()!.click());
  await settle();
  const extra = document.querySelector<HTMLElement>(".acpmux-quick-list .acpmux-quick-more-list [role^='menuitem']")!;
  await act(async () => extra.focus());
  const popup = extra.closest<HTMLElement>(".acpmux-quick-menu")!;
  await act(async () => {
    extra.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
  });
  await settle();
  expect(labels(list())).toContain("Codex a");
  expect(popup.contains(document.activeElement)).toBe(true);
});

// The browser layout suite measures actual popup height; JSDOM verifies which rows contribute
// content as the New Tab disclosure opens and closes.
test("on New Tab More models adds only the chosen tab's visible model rows", async () => {
  await openMenu(true);
  const initial = labels(list());
  expect(initial).toContain("Claude a");
  expect(initial).not.toContain("Claude old x");
  await act(async () => disclosure()!.click());
  await settle();
  const expected: string[] = [...initial.slice(0, -1), "Claude old x", "Claude old y", initial.at(-1)!];
  expect(labels(list())).toEqual(expected);
  await act(async () => disclosure()!.click());
  await settle();
  expect(labels(list())).toEqual(initial);
});

test("a chat rail switch replaces the visible model rows", async () => {
  await openMenu(false);
  expect(labels(list())).toContain("Claude a");
  expect(labels(list())).not.toContain("Codex a");
  const codex = document.querySelector<HTMLElement>('.acpmux-quick-rail-tab[aria-label="Codex"]')!;
  await act(async () => codex.click());
  await settle();
  expect(labels(list())).toContain("Codex a");
  expect(labels(list())).not.toContain("Claude a");
});

test("Fast mode exposes one checked menu row with a visual switch and no bare state word", async () => {
  await openMenu(false);
  const fast = document.querySelector<HTMLElement>(".acpmux-quick-fast")!;
  expect(fast.getAttribute("role")).toBe("menuitemcheckbox");
  expect(fast.getAttribute("aria-checked")).toBe("false");
  expect(fast.textContent?.trim()).toBe("Fast mode");
  await act(async () => fast.click());
  await settle();
  expect(document.querySelector(".acpmux-quick-fast")?.getAttribute("aria-checked")).toBe("true");
});

test("New Tab keeps Fast mode in the picker instead of adding a composer bolt", async () => {
  await openMenu(true);
  expect(document.querySelector(".acpmux-fast")).toBeNull();
  const fast = document.querySelector<HTMLElement>(".acpmux-quick-fast")!;
  expect(fast.getAttribute("role")).toBe("menuitemcheckbox");
  expect(fast.getAttribute("aria-checked")).toBe("false");
});

for (const newTab of [false, true]) {
  test(`Add harness is the only extra action with no hidden models (${newTab ? "New Tab" : "chat"})`, async () => {
    let added = 0;
    await openMenu(newTab, { noMore: true, onAddHarness: () => added++ });
    expect(labels(list())).not.toContain("More models");
    expect(labels(list())).not.toContain("Add harness…");
    const add = document.querySelector<HTMLButtonElement>(".acpmux-quick-rail-add")!;
    expect(add).not.toBeNull();
    expect(add.parentElement?.lastElementChild).toBe(add);
    await act(async () => add.click());
    expect(added).toBe(1);
    expect(document.querySelector(".acpmux-quick-menu")).toBeNull();
  });
}

test("expanded New Tab More models contains models only and keeps one Add in the rail", async () => {
  await openMenu(true, { onAddHarness() {} });
  expect(labels(list())).not.toContain("Add harness…");
  await act(async () => disclosure()!.click());
  await settle();
  expect(labels(list())).not.toContain("Add harness…");
  expect(document.querySelectorAll('[aria-label="Add harness…"]').length).toBe(1);
  const expanded = document.querySelector(".acpmux-quick-more-list")!;
  expect(labels(expanded)).toEqual(["Claude old x", "Claude old y"]);
});

for (const searchField of ["always", "typed", "long"] as const) {
  test(`rail arrows reach Add and return to the neighboring harness (${searchField} search)`, async () => {
    await openMenu(false, { onAddHarness() {}, searchField });
    const input = document.querySelector<HTMLInputElement>(".acpmux-quick-search input")!;
    const arrow = async (key: string) => {
      await act(async () =>
        document.activeElement!.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true })),
      );
      await settle();
    };
    const firstRow = document.querySelector<HTMLElement>('.acpmux-quick-list [role="menuitemradio"]')!;
    if (searchField !== "always") expect(input).toBeNull();
    await act(async () => (input ?? firstRow).focus());
    await arrow("ArrowLeft");
    const add = document.querySelector<HTMLButtonElement>(".acpmux-quick-rail-add")!;
    expect(document.activeElement).toBe(add);
    expect(labels(list())).toContain("Claude a");
    expect(add.getAttribute("aria-pressed")).toBeNull();
    for (const key of ["Enter", " "]) {
      const event = new dom!.window.KeyboardEvent("keydown", {
        key,
        bubbles: true,
        cancelable: true,
      });
      await act(async () => add.dispatchEvent(event));
      // Native buttons handle activation; the menu must not consume Space as search text.
      expect(event.defaultPrevented).toBe(false);
      expect(input?.value ?? "").toBe("");
    }
    await arrow("ArrowLeft");
    expect(labels(list())).toContain("Codex a");
    expect(document.activeElement).toBe(input ?? document.querySelector('[aria-label="Codex"].acpmux-quick-rail-tab'));
    await arrow("ArrowRight");
    expect(document.activeElement).toBe(add);
    expect(labels(list())).toContain("Codex a");
    await arrow("ArrowRight");
    expect(labels(list())).toContain("Claude a");
  });
}
