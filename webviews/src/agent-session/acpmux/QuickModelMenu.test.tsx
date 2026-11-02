// The compact model menu on the New Tab page (newTabComposer.ts): no 1 to 9 key hints, and More models is a row that shows the tab's other models in place
// (not a submenu), keeps the menu open, and leaves keyboard focus in the menu as the rail changes.
import { afterEach, expect, test } from "bun:test";
import React, { act, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { OnNewTab } from "./newTabComposer";
import type { QuickFamily, QuickModel, QuickProviderLook, QuickSearchField } from "./QuickModelMenu";
import type { SessionAuth } from "./sessionAuth";
import { effortLevel, openEffort } from "../../../test/support/effortDropdown";

let QuickModelMenu: typeof import("./QuickModelMenu").QuickModelMenu;
const loadQuickModelMenu = async () => {
  QuickModelMenu ??= (await import("./QuickModelMenu")).QuickModelMenu;
  return QuickModelMenu;
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

type HarnessOptions = {
  onAddHarness?: () => void;
  noMore?: boolean;
  searchField?: QuickSearchField;
  auth?: { verdict: SessionAuth; onLogin(): void };
};
function Harness({ newTab, onAddHarness, noMore, searchField, auth }: { newTab: boolean } & HarnessOptions) {
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
          auth,
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

for (const newTab of [false, true]) {
  for (const state of ["expired", "signedOut"] as const) {
    test(`${newTab ? "New Tab" : "chat"} keeps ${state} recovery available while searching before send`, async () => {
      let logins = 0;
      await openMenu(newTab, {
        searchField: "always",
        auth: {
          verdict: {
            state,
            source: "turn",
            evidenceAt: 1,
            harness: "claude",
            host: null,
            login: { kind: "terminal", command: "claude auth login" },
          },
          onLogin: () => logins++,
        },
      });
      const recovery = () =>
        [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
          (row) => row.textContent?.trim() === "Sign in again",
        );
      expect(recovery()).toBeDefined();
      const input = document.querySelector<HTMLInputElement>(".acpmux-quick-search input")!;
      await act(async () => {
        Object.getOwnPropertyDescriptor(dom!.window.HTMLInputElement.prototype, "value")!.set!.call(input, "opus");
        input.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
      });
      await settle();
      expect(input.value).toBe("opus");
      expect(recovery()).toBeDefined();
      await act(async () => recovery()!.click());
      expect(logins).toBe(1);
    });
  }
}

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

test("inline effort picks a different model and its level together; model names keep effort", async () => {
  const container = installDom();
  await loadQuickModelMenu();
  const picks: { id: string; effort?: string }[] = [];
  const effortPicks: string[] = [];
  function InlineHarness({
    combined = true,
    omitInlineEffort = false,
  }: {
    combined?: boolean;
    omitInlineEffort?: boolean;
  }) {
    const trigger = useRef<HTMLButtonElement | null>(null);
    const [open, setOpen] = useState(false);
    return (
      <QuickModelMenu
        open={open}
        onOpenChange={setOpen}
        trigger={trigger}
        chip={{ "data-menu": "model", label: "Model", title: "Model" }}
        onMore={() => {}}
        menu={{
          ...(omitInlineEffort ? {} : { inlineEffort: combined }),
          models: [],
          current: "a",
          onModel() {},
          effort: {
            levels: [
              { id: "low", name: "Low" },
              { id: "high", name: "High" },
              { id: "ultracode", name: "Ultracode" },
            ],
            current: "high",
            onPick: (value) => effortPicks.push(value),
          },
          families: {
            current: "claude",
            onPick: (row) => picks.push(row),
            list: [
              {
                id: "claude",
                name: "Claude",
                more: [],
                models: [
                  { id: "a", name: "Model A", family: "claude", efforts: ["low", "high"] },
                  { id: "b", name: "Model B", family: "claude", efforts: ["low"] },
                  { id: "c", name: "Model C", family: "claude", efforts: [] },
                ],
              },
            ],
          },
        }}
      >
        Model
      </QuickModelMenu>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<InlineHarness />);
  });
  const open = async () => {
    await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
    await settle();
  };
  await open();
  // The running Model A lists its own two levels and the session-only Ultracode (3); Model B only
  // its one (the menu held 4 levels across both rows before each got its own dropdown).
  expect(await openEffort(document, "Model A")).toHaveLength(3);
  expect(document.querySelector('[aria-label="Model A · Ultracode"]')).toBeTruthy();
  expect((await openEffort(document, "Model B")).map((item) => item.getAttribute("aria-label"))).toEqual([
    "Model B · Low",
  ]);
  expect(document.querySelector('[aria-label="Model B · High"]')).toBeNull();
  await act(async () => (await effortLevel(document, "Model A · Ultracode"))!.click());
  expect(effortPicks).toEqual(["ultracode"]);
  expect(picks).toEqual([]);
  await settle();
  await open();
  await act(async () => (await effortLevel(document, "Model B · Low"))!.click());
  expect(picks.map(({ id, effort }) => ({ id, effort }))).toEqual([{ id: "b", effort: "low" }]);
  await settle();
  await open();
  await act(async () => {
    const name = [...document.querySelectorAll<HTMLElement>(".acpmux-quick-item")].find((row) =>
      row.textContent?.includes("Model B"),
    );
    name!.click();
  });
  expect(picks.at(-1)?.id).toBe("b");
  expect(picks.at(-1)?.effort).toBeUndefined();
  await settle();
  await open();
  await act(async () => (await effortLevel(document, "Model A · Low"))!.click());
  expect(effortPicks).toEqual(["ultracode", "low"]);
  expect(picks.at(-1)?.id).toBe("b");
  expect(picks).toHaveLength(2);
  expect(picks.at(-1)?.effort).toBeUndefined();
  await settle();
  await act(async () => root!.render(<InlineHarness combined={false} />));
  await open();
  expect(document.querySelectorAll(".acpmux-quick-effort-trigger, .acpmux-quick-effort-segment")).toHaveLength(0);
  expect(labels(list())).toContain("Effort");
  await act(async () => root!.render(<InlineHarness omitInlineEffort />));
  await settle();
  expect(document.querySelectorAll(".acpmux-quick-effort-trigger, .acpmux-quick-effort-segment")).toHaveLength(0);
  expect(labels(list())).toContain("Effort");
});

test.each([
  ["Low", "low"],
  ["Ultracode", "ultracode"],
])("current-model inline %s pick keeps a searched Fast request on its plain tier", async (name, level) => {
  const container = installDom();
  await loadQuickModelMenu();
  const effortPicks: string[] = [];
  const fastPicks: boolean[] = [];
  const combos: QuickModel[] = [];
  function InlineFastHarness() {
    const trigger = useRef<HTMLButtonElement | null>(null);
    const [open, setOpen] = useState(false);
    return (
      <QuickModelMenu
        open={open}
        onOpenChange={setOpen}
        trigger={trigger}
        chip={{ "data-menu": "model", label: "Model", title: "Model" }}
        onMore={() => {}}
        menu={{
          inlineEffort: true,
          models: [],
          current: "a",
          onModel() {},
          effort: {
            levels: [
              { id: "low", name: "Low" },
              { id: "high", name: "High" },
              { id: "ultracode", name: "Ultracode" },
            ],
            current: "high",
            onPick: (value) => effortPicks.push(value),
          },
          fast: { checked: false, onChange: (value) => fastPicks.push(value) },
          families: {
            current: "claude",
            onPick: (model) => combos.push(model),
            list: [
              {
                id: "claude",
                name: "Claude",
                more: [],
                models: [{ id: "a", name: "Model A", family: "claude", efforts: ["low", "high"], fast: true }],
              },
            ],
          },
        }}
      >
        Model
      </QuickModelMenu>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<InlineFastHarness />);
  });
  await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
  await settle();
  await act(async () => (await effortLevel(document, `Model A · ${name}`))!.click());
  // The level goes through the reported option (Ultracode is no catalog effort a combo could land);
  // Fast goes through the combo, which maps it onto the option's plain tier, never the toggle, which
  // would restore a remembered ultrafast.
  expect(effortPicks).toEqual([level]);
  expect(combos.map(({ id, effort, fast }) => ({ id, effort, fast }))).toEqual([
    { id: "a", effort: undefined, fast: true },
  ]);
  expect(fastPicks).toEqual([]);
});

test("provider submenu and expanded rows keep the current model's Effort fallback", async () => {
  const model = {
    id: "a",
    name: "Model A",
    family: "claude",
    efforts: ["low", "high"],
    offers: [
      { id: "a-anthropic", name: "Model A", family: "claude", efforts: ["low", "high"], provider: "Anthropic" },
      { id: "a-openai", name: "Model A", family: "claude", efforts: ["low", "high"], provider: "OpenAI" },
    ],
  };
  for (const providerLook of ["submenu", "expanded"] as const) {
    const container = installDom();
    await loadQuickModelMenu();
    function ProviderHarness() {
      const trigger = useRef<HTMLButtonElement | null>(null);
      const [open, setOpen] = useState(false);
      return (
        <QuickModelMenu
          open={open}
          onOpenChange={setOpen}
          trigger={trigger}
          chip={{ "data-menu": "model", label: "Model", title: "Model" }}
          onMore={() => {}}
          menu={{
            inlineEffort: true,
            providers: providerLook,
            models: [],
            current: "a",
            onModel() {},
            effort: {
              levels: [
                { id: "low", name: "Low" },
                { id: "high", name: "High" },
              ],
              current: "high",
              onPick() {},
            },
            families: {
              current: "claude",
              onPick() {},
              list: [{ id: "claude", name: "Claude", more: [], models: [model] }],
            },
          }}
        >
          Model
        </QuickModelMenu>
      );
    }
    await act(async () => {
      root = createRoot(container);
      root.render(<ProviderHarness />);
    });
    await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
    await settle();
    expect(document.querySelectorAll(".acpmux-quick-effort-segment")).toHaveLength(0);
    expect(labels(list())).toContain("Effort");
    await act(async () => {
      root!.unmount();
      root = undefined;
    });
  }
});

test("the running model keeps session-only effort levels and calls effort.onPick", async () => {
  const container = installDom();
  await loadQuickModelMenu();
  const picked: string[] = [];
  function CurrentModel() {
    const trigger = useRef<HTMLButtonElement | null>(null);
    const [open, setOpen] = useState(false);
    return (
      <QuickModelMenu
        open={open}
        onOpenChange={setOpen}
        trigger={trigger}
        chip={{ "data-menu": "model", label: "Model", title: "Model" }}
        onMore={() => {}}
        menu={{
          inlineEffort: true,
          models: [{ id: "a", name: "Model A", efforts: ["low", "high"] }],
          current: "a",
          onModel() {},
          // A menu without families opts into inline rows only with the combined callback.
          onModelEffort() {},
          effort: {
            levels: [
              { id: "low", name: "Low" },
              { id: "high", name: "High" },
              { id: "ultracode", name: "Ultracode" },
            ],
            current: "high",
            onPick: (value) => picked.push(value),
          },
        }}
      >
        Model
      </QuickModelMenu>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<CurrentModel />);
  });
  await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
  await settle();
  expect(await openEffort(document, "Model A")).toHaveLength(3);
  await act(async () => (await effortLevel(document, "Model A · Ultracode"))!.click());
  expect(picked).toEqual(["ultracode"]);
});

test("the fallback Effort submenu remains when the running model is folded away", async () => {
  const container = installDom();
  await loadQuickModelMenu();
  function FoldedModel() {
    const trigger = useRef<HTMLButtonElement | null>(null);
    const [open, setOpen] = useState(false);
    return (
      <QuickModelMenu
        open={open}
        onOpenChange={setOpen}
        trigger={trigger}
        chip={{ "data-menu": "model", label: "Model", title: "Model" }}
        onMore={() => {}}
        menu={{
          inlineEffort: true,
          models: [{ id: "top", name: "Top model", efforts: ["low", "high"] }],
          current: "folded",
          onModel() {},
          effort: {
            levels: [
              { id: "low", name: "Low" },
              { id: "high", name: "High" },
            ],
            current: "high",
            onPick() {},
          },
        }}
      >
        Model
      </QuickModelMenu>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<FoldedModel />);
  });
  await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
  await settle();
  expect(
    [...document.querySelectorAll<HTMLElement>(".acpmux-quick-sub")].some((row) =>
      row.textContent?.startsWith("Effort"),
    ),
  ).toBe(true);
});

for (const location of ["top", "more", "provider"] as const) {
  for (const capability of ["absent", "empty"] as const) {
    test(`the current ${location} model respects ${capability} effort capability in every control`, async () => {
      const container = installDom();
      await loadQuickModelMenu();
      const current: QuickModel = {
        id: "current",
        name: "Current model",
        family: "claude",
        ...(capability === "empty" ? { efforts: [] } : {}),
      };
      const top: QuickModel = { id: "top", name: "Top model", family: "claude" };
      function CapabilityMenu() {
        const trigger = useRef<HTMLButtonElement | null>(null);
        const [open, setOpen] = useState(false);
        return (
          <QuickModelMenu
            open={open}
            onOpenChange={setOpen}
            trigger={trigger}
            chip={{ "data-menu": "model", label: "Model", title: "Model" }}
            onMore={() => {}}
            menu={{
              inlineEffort: true,
              models: [],
              current: "current",
              onModel() {},
              effort: {
                levels: [
                  { id: "low", name: "Low" },
                  { id: "high", name: "High" },
                  { id: "ultracode", name: "Ultracode" },
                ],
                current: "high",
                onPick() {},
              },
              families: {
                current: "claude",
                onPick() {},
                list: [
                  {
                    id: "claude",
                    name: "Claude",
                    models:
                      location === "top"
                        ? [current]
                        : location === "provider"
                          ? [{ ...top, offers: [{ ...current, provider: "Route" }] }]
                          : [top],
                    more: location === "more" ? [current] : [],
                  },
                ],
              },
            }}
          >
            Model
          </QuickModelMenu>
        );
      }
      await act(async () => {
        root = createRoot(container);
        root.render(<CapabilityMenu />);
      });
      await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
      await settle();
      const segments = await openEffort(document);
      const fallback = [...document.querySelectorAll(".acpmux-quick-sub")].find((row) =>
        row.textContent?.startsWith("Effort"),
      );
      if (capability === "empty") {
        expect(segments).toHaveLength(0);
        expect(fallback).toBeUndefined();
      } else {
        expect(segments.length > 0 || Boolean(fallback)).toBe(true);
      }
      expect(document.querySelectorAll('[role^="menuitem"] [role^="menuitem"]')).toHaveLength(0);
    });
  }
}

test.each(["submenu", "expanded"] as QuickProviderLook[])(
  "provider %s controls never nest menu items",
  async (providers) => {
    const container = installDom();
    await loadQuickModelMenu();
    function ProviderMenu() {
      const trigger = useRef<HTMLButtonElement | null>(null);
      const [open, setOpen] = useState(false);
      return (
        <QuickModelMenu
          open={open}
          onOpenChange={setOpen}
          trigger={trigger}
          chip={{ "data-menu": "model", label: "Model", title: "Model" }}
          onMore={() => {}}
          menu={{
            inlineEffort: true,
            models: [
              {
                id: "a",
                name: "Shared model",
                efforts: ["low", "high"],
                offers: [
                  { id: "a", name: "Shared model", family: "", provider: "Route A" },
                  { id: "b", name: "Shared model", family: "", provider: "Route B" },
                ],
              },
            ],
            providers,
            current: "a",
            onModel() {},
            effort: {
              levels: [
                { id: "low", name: "Low" },
                { id: "high", name: "High" },
              ],
              current: "high",
              onPick() {},
            },
          }}
        >
          Model
        </QuickModelMenu>
      );
    }
    await act(async () => {
      root = createRoot(container);
      root.render(<ProviderMenu />);
    });
    await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
    await settle();
    if (providers === "submenu") {
      const row = [...document.querySelectorAll<HTMLElement>(".acpmux-quick-sub")].find((node) =>
        node.textContent?.includes("Shared model"),
      )!;
      await act(async () => row.click());
      await settle();
    }
    expect(
      [...document.querySelectorAll('[role="menuitemradio"]')].some((row) => row.textContent?.includes("Route B")),
    ).toBe(true);
    expect(document.querySelectorAll('[role^="menuitem"] [role^="menuitem"]')).toHaveLength(0);
  },
);

test("an empty harness list does not claim an empty search had no matches", async () => {
  const container = installDom();
  await loadQuickModelMenu();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <QuickModelMenu
        open
        onOpenChange={() => undefined}
        trigger={{ current: null }}
        chip={{ "data-menu": "model", label: "Model", title: "Model" }}
        onMore={() => undefined}
        menu={{
          models: [],
          current: undefined,
          onModel: () => undefined,
          families: {
            list: [{ id: "claude", name: "Claude Code", models: [], more: [] }],
            current: "claude",
            onPick: () => undefined,
          },
        }}
      >
        Model
      </QuickModelMenu>,
    );
  });
  await settle();
  const text = document.querySelector(".acpmux-quick-note")?.textContent?.trim();
  expect(text).toBe("No models yet. Refresh to ask the agent again.");
  expect(text).not.toBe("No matching models");
});

// https://github.com/manaflow-ai/cmux/issues/29915: effort showed only as "Medium >" on the running
// row; the chat's own tab drew a blank column on its other models until pointed at.
test("every model row with levels names one at rest, on the chat's own tab too", async () => {
  const container = installDom();
  await loadQuickModelMenu();
  function OwnTabHarness() {
    const trigger = useRef<HTMLButtonElement | null>(null);
    const [open, setOpen] = useState(false);
    return (
      <QuickModelMenu
        open={open}
        onOpenChange={setOpen}
        trigger={trigger}
        chip={{ "data-menu": "model", label: "Model", title: "Model" }}
        onMore={() => {}}
        menu={{
          inlineEffort: true,
          models: [],
          current: "opus",
          onModel() {},
          effort: {
            current: "high",
            levels: [
              { id: "low", name: "Low" },
              { id: "high", name: "High" },
            ],
            onPick() {},
          },
          families: {
            current: "claude",
            onPick() {},
            list: [
              {
                id: "claude",
                name: "Claude",
                more: [],
                models: [
                  { id: "opus", name: "Opus", family: "claude", efforts: ["low", "high"] },
                  {
                    id: "sonnet",
                    name: "Sonnet",
                    family: "claude",
                    efforts: ["low", "medium"],
                    defaultEffort: "medium",
                  },
                ],
              },
            ],
          },
        }}
      >
        Model
      </QuickModelMenu>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<OwnTabHarness />);
  });
  await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
  await settle();
  const rowOf = (name: string) =>
    [...document.querySelectorAll<HTMLElement>(".acpmux-quick-model-effort")].find((node) =>
      node.querySelector(".acpmux-menu-label")?.textContent?.includes(name),
    )!;
  const opus = rowOf("Opus");
  expect(opus.hasAttribute("data-running")).toBe(true);
  expect(opus.querySelector(".acpmux-quick-effort-now")?.textContent).toContain("High");
  const sonnet = rowOf("Sonnet");
  expect(sonnet.hasAttribute("data-held")).toBe(true);
  expect(sonnet.querySelector(".acpmux-quick-effort-now")?.textContent).toContain("Medium");
});

// Leo 2026-10-31: "WHY THE FUCK IS THERE NO FUCKING FAST MODE FOR FUCKIGN CODEX". Another tab's
// models get the same Fast mode row and effort column as the chat's own: the row holds the choice
// (off as the menu opens) and a model picked there lands with it.
test("another tab whose models honor Fast mode draws the Fast row and lands its pick with it", async () => {
  const container = installDom();
  await loadQuickModelMenu();
  const picks: QuickModel[] = [];
  function OtherTabHarness() {
    const trigger = useRef<HTMLButtonElement | null>(null);
    const [open, setOpen] = useState(false);
    return (
      <QuickModelMenu
        open={open}
        onOpenChange={setOpen}
        trigger={trigger}
        chip={{ "data-menu": "model", label: "Model", title: "Model" }}
        onMore={() => {}}
        menu={{
          inlineEffort: true,
          models: [],
          current: "opus",
          onModel() {},
          fast: { checked: false, onChange() {} },
          families: {
            current: "claude",
            onPick: (model) => picks.push(model),
            list: [
              {
                id: "claude",
                name: "Claude",
                more: [],
                models: [{ id: "opus", name: "Opus", family: "claude", efforts: ["low", "medium"], canFast: true }],
              },
              {
                id: "codex",
                name: "Codex",
                more: [],
                models: [
                  {
                    id: "sol",
                    name: "Sol",
                    family: "codex",
                    efforts: ["low", "medium", "high"],
                    defaultEffort: "medium",
                    canFast: true,
                  },
                ],
              },
            ],
          },
        }}
      >
        Model
      </QuickModelMenu>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<OtherTabHarness />);
  });
  await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
  await settle();
  await act(async () => document.querySelector<HTMLElement>('.acpmux-quick-rail-tab[aria-label="Codex"]')!.click());
  await settle();
  // The effort column names the level a pick lands, at rest.
  const row = [...document.querySelectorAll<HTMLElement>(".acpmux-quick-model-effort")].find((node) =>
    node.textContent?.includes("Sol"),
  )!;
  expect(row.hasAttribute("data-held")).toBe(true);
  expect(row.querySelector(".acpmux-quick-effort-now")?.textContent).toContain("Medium");
  const fast = document.querySelector<HTMLElement>(".acpmux-quick-fast")!;
  expect(fast.getAttribute("aria-checked")).toBe("false");
  await act(async () => fast.click());
  await settle();
  expect(document.querySelector(".acpmux-quick-fast")?.getAttribute("aria-checked")).toBe("true");
  const sol = [...document.querySelectorAll<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]')].find((node) =>
    node.textContent?.includes("Sol"),
  )!;
  await act(async () => sol.click());
  await settle();
  expect(picks.map(({ id, fast }) => ({ id, fast }))).toEqual([{ id: "sol", fast: true }]);
});

// Leo 2026-10-31: "FUCKING HELL WHY DO YOU GUYS STILLLLLLLLLLLLLLLLLLLLLL SHOW THESE AS SEPARATE
// HARNESSES" / "THE FUCKING APP SERVER THE FUCKING SR" / "WHERE IS THE FUCKING ACCOUNTS". The
// symbols row has one tab per model family; a family's routes (direct CLI, the SR route, the app
// server, a work login) are an Account choice in the menu, never tabs.
const route = (id: string, name: string, group: string, extra: Partial<QuickFamily> = {}): QuickFamily => ({
  id,
  name,
  group,
  models: [{ id: `${id}-m`, name: `${name} model`, family: id }],
  more: [],
  ...extra,
});
const familyRail = [
  route("claude", "Claude Code", "claude"),
  route("claude-sr2", "Claude Code (sr2)", "claude"),
  route("claude-work", "Claude Code (work)", "claude", { launch: true, models: [] }),
  route("codex", "Codex", "openai"),
  route("codex-app-server", "Codex (app-server)", "openai"),
  route("vercel", "Vercel AI Gateway", "vercel"),
];

test("familyTabs: one tab per model family, its routes in rail order", async () => {
  const { familyTabs } = await import("./QuickModelMenu");
  const tabs = familyTabs(familyRail);
  expect(tabs.map((tab) => [tab.key, tab.name, tab.routes.map((entry) => entry.id)])).toEqual([
    ["claude", "Claude Code", ["claude", "claude-sr2", "claude-work"]],
    ["openai", "Codex", ["codex", "codex-app-server"]],
    ["vercel", "Vercel AI Gateway", ["vercel"]],
  ]);
});

test("searchGroups: a family's routes share one heading and list a model once", async () => {
  const { searchGroups } = await import("./QuickModelMenu");
  const found: QuickModel[] = [
    { id: "opus", name: "Opus", family: "claude-sr2" },
    { id: "opus", name: "Opus", family: "claude" },
    { id: "sol", name: "Sol", family: "codex-app-server" },
  ];
  const groups = searchGroups(found, familyRail, "claude");
  expect(groups.map((group) => [group.name, group.rows.map((row) => `${row.family}/${row.id}`)])).toEqual([
    ["Claude Code", ["claude/opus"]],
    ["Codex", ["codex-app-server/sol"]],
  ]);
});

test("the symbols row draws one tab per family and the Account row switches its route", async () => {
  const container = installDom();
  await loadQuickModelMenu();
  const launched: string[] = [];
  function FamilyHarness() {
    const trigger = useRef<HTMLButtonElement | null>(null);
    const [open, setOpen] = useState(false);
    return (
      <QuickModelMenu
        open={open}
        onOpenChange={setOpen}
        trigger={trigger}
        chip={{ "data-menu": "model", label: "Model", title: "Model" }}
        onMore={() => {}}
        menu={{
          models: [],
          current: "claude-sr2-m",
          onModel() {},
          harnessPlacement: "symbols",
          families: { current: "claude-sr2", onPick() {}, onLaunch: (id) => launched.push(id), list: familyRail },
        }}
      >
        Model
      </QuickModelMenu>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(<FamilyHarness />);
  });
  await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
  await settle();
  const tabNames = () =>
    [...document.querySelectorAll<HTMLElement>(".acpmux-quick-rail-tab:not(.acpmux-quick-rail-add)")].map((tab) =>
      tab.getAttribute("aria-label"),
    );
  expect(tabNames()).toEqual(["Claude Code", "Codex", "Vercel AI Gateway"]);
  // The Claude tab opens on the chat's own route, and the Account row names it.
  expect(document.querySelector('.acpmux-quick-rail-tab[aria-pressed="true"]')?.getAttribute("aria-label")).toBe(
    "Claude Code",
  );
  expect(labels(list())).toContain("Claude Code (sr2) model");
  const account = () => document.querySelector<HTMLElement>(".acpmux-quick-account")!;
  expect(account().textContent).toContain("Claude Code (sr2)");
  await act(async () => account().click());
  await settle();
  const routes = () => [...document.querySelectorAll<HTMLElement>(".acpmux-quick-route")];
  expect(routes().map((item) => item.querySelector(".acpmux-menu-label")?.textContent)).toEqual([
    "Claude Code",
    "Claude Code (sr2)",
    "Claude Code (work)",
  ]);
  expect(routes()[1]!.getAttribute("aria-checked")).toBe("true");
  await act(async () => routes()[0]!.click());
  await settle();
  expect(labels(list())).toContain("Claude Code model");
  expect(labels(list())).not.toContain("Claude Code (sr2) model");
  // A route with no models of its own starts its harness, as its tab did.
  if (!document.querySelector(".acpmux-quick-route")) {
    await act(async () => account().click());
    await settle();
  }
  await act(async () => routes()[2]!.click());
  await settle();
  expect(launched).toEqual(["claude-work"]);
  // Codex is one tab: its default route is its first.
  if (!document.querySelector(".acpmux-quick-account")) {
    await act(async () => container.querySelector<HTMLButtonElement>("button[data-menu='model']")!.click());
    await settle();
  }
  await act(async () => document.querySelector<HTMLElement>('.acpmux-quick-rail-tab[aria-label="Codex"]')!.click());
  await settle();
  expect(labels(list())).toContain("Codex model");
  expect(account().textContent).toContain("Codex");
});
