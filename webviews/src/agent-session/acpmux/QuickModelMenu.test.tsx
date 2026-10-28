// The compact model menu on the New Tab page (newTabComposer.ts): no 1 to 9 key hints, and More models is a row that shows the tab's other models in place
// (not a submenu), keeps the menu open, and leaves keyboard focus in the menu as the rail changes.
import { afterEach, expect, test } from "bun:test";
import React, { act, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { OnNewTab } from "./newTabComposer";
import { QuickModelMenu, type QuickFamily, type QuickModel, type QuickProviderLook } from "./QuickModelMenu";

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

function Harness({ newTab }: { newTab: boolean }) {
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
          models: [],
          current: "claude-a",
          onModel() {},
          fast: { checked: fast, onChange: setFast },
          families: {
            list: [family("claude", "Claude"), family("codex", "Codex")],
            current: "claude",
            onPick() {},
          },
        }}
        onMore={() => {}}
      >
        Model
      </QuickModelMenu>
    </OnNewTab.Provider>
  );
}

async function openMenu(newTab: boolean) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<Harness newTab={newTab} />);
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

test("inline effort picks a different model and its level together; model names keep effort", async () => {
  const container = installDom();
  const picks: { id: string; effort?: string }[] = [];
  const effortPicks: string[] = [];
  function InlineHarness() {
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
          current: "a",
          onModel() {},
          effort: {
            levels: [
              { id: "low", name: "Low" },
              { id: "high", name: "High" },
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
  expect(document.querySelectorAll('[role^="menuitem"] [role^="menuitem"]')).toHaveLength(0);
  expect(document.querySelectorAll(".acpmux-quick-effort-segment")).toHaveLength(3);
  expect(document.querySelector('[aria-label="Model B · High"]')).toBeNull();
  await act(async () => (document.querySelector('[aria-label="Model B · Low"]') as HTMLElement).click());
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
  await act(async () => (document.querySelector('[aria-label="Model A · Low"]') as HTMLElement).click());
  expect(effortPicks).toEqual(["low"]);
});

test("the running model keeps session-only effort levels and calls effort.onPick", async () => {
  const container = installDom();
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
          models: [{ id: "a", name: "Model A", family: "", efforts: ["low", "high"] }],
          current: "a",
          onModel() {},
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
  expect(document.querySelectorAll(".acpmux-quick-effort-segment")).toHaveLength(3);
  await act(async () => (document.querySelector('[aria-label="Model A · Ultracode"]') as HTMLElement).click());
  expect(picked).toEqual(["ultracode"]);
});

test("the fallback Effort submenu remains when the running model is folded away", async () => {
  const container = installDom();
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
          models: [{ id: "top", name: "Top model", family: "", efforts: ["low", "high"] }],
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
      const segments = document.querySelectorAll(".acpmux-quick-effort-segment");
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
