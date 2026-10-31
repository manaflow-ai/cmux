// The Prototype look's model controls (Lucas 2026-10-30, T3 Code's composer): the model chip opens
// the model panel at once (an icon rail with Starred first, the search field, one row per model with
// its harness under the name, a number key and a star), Claude's and Codex's tabs show four models
// with the rest under More models, and the level and Fast mode are a chip of their own. The real
// composer, catalog and menus, in JSDOM.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import type { UpdateOffer } from "../src/agent-session/acpmux/HarnessHealthNotice";
import { setComposerLook } from "../src/agent-session/acpmux/composerLook";
import { DEFAULT_COMPOSER, setComposerSettings } from "../src/agent-session/acpmux/composerSettings";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

beforeEach(() => setComposerLook("prototype", { remember: false }));

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  setComposerSettings(DEFAULT_COMPOSER);
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu")) popup.remove();
});

afterAll(() => {
  // The look is module state: leave the default for the files after this one.
  setComposerLook("claude", { remember: false });
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Sent = { method: "model" | "effort" | "route"; value: string | null };

/// A Claude chat on the compact menu, its accounts the routes `listed` (acpmux's reply), and the
/// chat bound to `active`; launch configurations appear as named harness entries, never Profile.
async function mount(
  listed: unknown,
  options: {
    fast?: boolean;
    refuse?: boolean;
    turnCount?: number;
    model?: string;
    effort?: string;
    folderProfile?: boolean;
    currentFolder?: boolean;
    update?: UpdateOffer;
  } = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { UpdateOfferContext } = await import("../src/agent-session/acpmux/HarnessHealthNotice");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const { ChatAccountsContext, readChatAccounts } = await import("../src/agent-session/acpmux/chatAccounts");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const acpmux: Snapshot["catalog"] = [
    ...BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
      id: harness.id,
      name: harness.name,
      family: harness.families[0],
      models: harness.models.map((model) => ({ id: model.id, name: model.name })),
    })),
    ...(options.folderProfile
      ? [
          {
            id: "machine-profile",
            name: "Build machine",
            folder: { folder: "/Users/me/app", state: "enabled" as const },
            models: [{ id: "machine-model", name: "Machine model" }],
          },
        ]
      : []),
  ] as Snapshot["catalog"];
  const sent: Sent[] = [];
  const asked: string[] = [];
  const added: string[] = [];
  const accounts = {
    list: async (sessionId: string) => {
      asked.push(sessionId);
      return readChatAccounts(listed);
    },
    set: async (_sessionId: string, routeId: string | null) => {
      sent.push({ method: "route", value: routeId });
      if (options.refuse) throw new Error("route.unavailable");
    },
  };
  function Host() {
    const initialHarness = options.currentFolder ? "machine-profile" : "claude";
    const initialModel = options.currentFolder ? "machine-model" : "claude-opus-5-5";
    const [state, setState] = useState({
      model: options.model ?? initialModel,
      effort: options.effort ?? "medium",
      fast: "off",
      harness: initialHarness,
    });
    const snapshot: Snapshot = {
      type: "snapshot",
      protocolVersion: 1,
      rows: [],
      sessions: [],
      connection: "test",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      catalog: acpmux,
      summary: {
        sessionId: "s1",
        harness: state.harness,
        model: state.model,
        turnCount: options.turnCount ?? 0,
        configOptions: [
          {
            id: "effort",
            name: "Effort",
            category: "thought_level",
            currentValue: state.effort,
            options: [...(options.effort === "default" ? ["default"] : []), "low", "medium", "high"].map((value) => ({
              value,
              name: value,
            })),
          },
          ...(options.fast
            ? [
                {
                  id: "fast-mode",
                  name: "Fast Mode",
                  currentValue: state.fast,
                  options: [
                    { value: "off", name: "Off" },
                    { value: "on", name: "On" },
                  ],
                },
              ]
            : []),
        ],
      },
    } as Snapshot;
    const picker = usePickerCatalog(snapshot.catalog, { harness: state.harness }, snapshot.sessions);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={(model) => {
          sent.push({ method: "model", value: model });
          setState((current) => ({ ...current, model }));
        }}
        onMode={() => undefined}
        onEffort={(id, value) => {
          sent.push({ method: "effort", value });
          setState((current) => (id === "fast-mode" ? { ...current, fast: value } : { ...current, effort: value }));
        }}
        showPlan={false}
        onAddAgent={() => added.push("add")}
      />
    );
  }
  root = createRoot(host);
  const client = new QueryClient();
  // A fresh element each time: the composer re-renders as a live chat streams.
  const tree = () => (
    <QueryClientProvider client={client}>
      <ChatAccountsContext.Provider value={accounts}>
        <UpdateOfferContext.Provider value={options.update}>
          <Host />
        </UpdateOfferContext.Provider>
      </ChatAccountsContext.Provider>
    </QueryClientProvider>
  );
  await act(async () => root!.render(tree()));
  const rerender = () => act(async () => root!.render(tree()));
  return { sent, asked, added, rerender };
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const modelChip = () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!;
const effortChip = () => host.querySelector<HTMLButtonElement>('[data-menu="Effort"]');
const panel = () => doc().querySelector<HTMLElement>(".acpmux-quick-panel");
const rows = () => [...panel()!.querySelectorAll<HTMLElement>('.acpmux-quick-two[role="menuitemradio"]')];
const names = () => rows().map((row) => row.querySelector(".acpmux-quick-label .acpmux-menu-label")?.textContent ?? "");
const railTab = (name: string) =>
  [...panel()!.querySelectorAll<HTMLElement>(".acpmux-quick-rail-tab")].find((tab) =>
    tab.getAttribute("aria-label")?.startsWith(name),
  );
const click = async (element: HTMLElement) => {
  await act(async () => element.click());
  await settle();
};

test("the Prototype model chip opens the model panel at once, one row per model with its harness", async () => {
  await mount({ routes: [] });
  // The chip names the model alone: the level is the effort chip's.
  expect(modelChip().textContent).toContain("Opus 5.5");
  expect(modelChip().textContent).not.toContain("Medium");
  expect(effortChip()?.textContent).toContain("Medium");
  await click(modelChip());
  const popup = panel();
  expect(popup).not.toBeNull();
  // No short menu first: the rail (Starred, then the harnesses), the search field and the models.
  expect(popup!.querySelector(".acpmux-quick-rail")).not.toBeNull();
  expect(popup!.querySelector(".acpmux-quick-search input")).not.toBeNull();
  expect(popup!.querySelector(".acpmux-quick-rail-tab")?.getAttribute("aria-label")).toBe("Starred");
  expect(names()).toContain("Opus 5.5");
  // Each row names its harness under the model, and the running one shows its check, not a key.
  for (const row of rows()) expect(row.querySelector(".acpmux-quick-two-sub")?.textContent).toBeTruthy();
  const running = rows().find((row) => row.textContent?.includes("Opus 5.5"))!;
  expect(running.getAttribute("aria-checked")).toBe("true");
  expect(running.querySelector(".acpmux-quick-key")).toBeNull();
  expect(rows().filter((row) => row.querySelector(".acpmux-quick-key")).length).toBe(rows().length - 1);
});

test("Claude's and Codex's tabs show four models and keep the rest under More models", async () => {
  await mount({ routes: [] });
  await click(modelChip());
  expect(rows().length).toBeLessThanOrEqual(4);
  const codex = railTab("Codex");
  expect(codex).toBeDefined();
  await click(codex!);
  expect(rows()).toHaveLength(4);
  const more = panel()!.querySelector<HTMLElement>(".acpmux-quick-disclosure");
  expect(more?.textContent).toContain("More models");
  await click(more!);
  expect(panel()!.querySelectorAll('.acpmux-quick-more-list [role="menuitemradio"]').length).toBeGreaterThan(0);
});

test("the effort chip sets the level and Fast mode, and the model panel draws no Fast row", async () => {
  const { sent } = await mount({ routes: [] }, { fast: true });
  await click(modelChip());
  expect(panel()!.querySelector(".acpmux-quick-fast")).toBeNull();
  await act(async () => doc().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
  await settle();
  await click(effortChip()!);
  const effortMenu = doc().querySelector<HTMLElement>(".acpmux-effort-menu")!;
  const groups = [...effortMenu.querySelectorAll(".ui-menu-group-label")].map((label) => label.textContent);
  expect(groups).toEqual(["Reasoning", "Fast Mode"]);
  const item = (name: string) =>
    [...doc().querySelectorAll<HTMLElement>(".acpmux-effort-menu .acpmux-effort-item")].find(
      (row) => row.querySelector(".acpmux-menu-label")?.textContent === name,
    )!;
  expect(item("Standard").getAttribute("aria-checked")).toBe("true");
  await click(item("High"));
  expect(sent).toContainEqual({ method: "effort", value: "high" });
  await click(effortChip()!);
  await click(item("Fast"));
  expect(sent).toContainEqual({ method: "effort", value: "on" });
  // A press on the checked row changes nothing: Fast stays on.
  const before = sent.length;
  await click(effortChip()!);
  expect(item("Fast").getAttribute("aria-checked")).toBe("true");
  await click(item("Fast"));
  expect(sent.slice(before)).toEqual([]);
});

test("a running older model stays among Claude's four rows", async () => {
  await mount({ routes: [] }, { model: "claude-opus-4-8" });
  await click(modelChip());
  expect(rows()).toHaveLength(4);
  expect(names()).toContain("Opus 4.8");
  expect(
    rows()
      .find((row) => row.textContent?.includes("Opus 4.8"))
      ?.getAttribute("aria-checked"),
  ).toBe("true");
});

test("Starred is always on the rail, and a row's star adds its model without picking it", async () => {
  const { sent } = await mount({ routes: [] });
  await click(modelChip());
  await click(railTab("Starred")!);
  expect(panel()!.textContent).toContain("No starred models.");
  await click(railTab("Claude")!);
  const sonnet = rows().find((row) => row.textContent?.includes("Sonnet 5.5"))!;
  const star = sonnet.querySelector<HTMLElement>(".acpmux-quick-star")!;
  expect(star.getAttribute("aria-pressed")).toBe("false");
  await click(star);
  // The press was the star's: no model was picked and the panel stays open.
  expect(sent.filter((entry) => entry.method === "model")).toEqual([]);
  expect(panel()).not.toBeNull();
  await click(railTab("Starred")!);
  expect(names()).toEqual(["Sonnet 5.5"]);
  expect(rows()[0]!.querySelector(".acpmux-quick-star")?.getAttribute("aria-pressed")).toBe("true");
});
