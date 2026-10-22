// Leo 2026-10-18: the model chip opens a short Claude Code style menu: a rail of harnesses (Starred,
// Claude, Codex, others) beside numbered models, then Effort, More models and Account beside their
// rows. Account lists the acpmux routes that serve the chat and switches the chat's route. Since
// Leo 2026-10-20 it is every composer's one model button ("Opus 5.5  Medium"): no effort chip, no
// bolt, and Fast mode is the menu's last row, a checkbox. The real composer, catalog and menu, in
// JSDOM.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";

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
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu")) popup.remove();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Sent = { method: "model" | "effort" | "route"; value: string | null };

/// A Claude chat on the compact menu, its accounts the routes `listed` (acpmux's reply), and the
/// chat bound to `active`.
async function mount(
  listed: unknown,
  options: { fast?: boolean; refuse?: boolean; turnCount?: number; model?: string; effort?: string } = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const { ChatAccountsContext, readChatAccounts } = await import("../src/agent-session/acpmux/chatAccounts");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const acpmux: Snapshot["catalog"] = BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
    id: harness.id,
    name: harness.name,
    family: harness.families[0],
    models: harness.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
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
    const [state, setState] = useState({
      model: options.model ?? "claude-opus-5-5",
      effort: options.effort ?? "medium",
      fast: "off",
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
        harness: "claude",
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
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" }, snapshot.sessions);
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
        <Host />
      </ChatAccountsContext.Provider>
    </QueryClientProvider>
  );
  await act(async () => root!.render(tree()));
  const rerender = () => act(async () => root!.render(tree()));
  return { sent, asked, added, rerender };
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const chipButton = () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!;
const menu = () => doc().querySelector<HTMLElement>(".acpmux-quick-menu");
/// The model rows (the rail's tabs are radio items too).
const modelRows = (popup: HTMLElement) => [
  ...popup.querySelectorAll<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]'),
];
const modelNames = (popup: HTMLElement) =>
  modelRows(popup).map((row) => row.querySelector(".acpmux-menu-label")?.textContent ?? "");
const railTabs = () => [...menu()!.querySelectorAll<HTMLElement>(".acpmux-quick-rail-tab")];
const key = (value: string) =>
  act(async () => {
    menu()!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: value, bubbles: true }));
  });
const menus = () => [...doc().querySelectorAll<HTMLElement>(".acpmux-quick-menu")];
const itemsOf = (popup: HTMLElement | undefined) =>
  [...(popup?.querySelectorAll<HTMLElement>('[role^="menuitem"]') ?? [])].map((item) =>
    item.textContent?.replace("✓", "").trim(),
  );

async function open() {
  await act(async () => chipButton().click());
  await settle();
}

async function openSub(name: string) {
  const trigger = [...menu()!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.startsWith(name),
  );
  expect(trigger, `${name} row in ${itemsOf(menu()!).join(", ")}`).toBeDefined();
  await act(async () => trigger!.click());
  await settle();
  return menus().at(-1)!;
}

test("the compact chip names the model and its effort, and a click opens the short menu", async () => {
  await mount({ routes: [] });
  expect(chipButton().textContent).toContain("Opus 5.5");
  expect(chipButton().textContent).toContain("Medium");
  // No separate effort chip: Effort is a row of the menu.
  expect(host.querySelector(".acpmux-effort")).toBeNull();
  await open();
  expect(menu()?.textContent).toContain("Model · this session");
  expect(doc().querySelector(".acpmux-mp")).toBeNull();
  const rows = itemsOf(menu()!);
  expect(rows.some((row) => row?.startsWith("Effort") && row.includes("Medium"))).toBe(true);
  expect(rows.some((row) => row?.startsWith("Account"))).toBe(true);
  // Claude Code's order: the models, Effort, More models, then Account last.
  expect(
    rows
      .filter((row) => /^(Effort|More models|Account)/.test(row ?? ""))
      .map((row) => row?.match(/^(Effort|More models|Account)/)?.[0]),
  ).toEqual(["Effort", "More models", "Account"]);
});

test("a number key picks that model in place", async () => {
  const { sent } = await mount({ routes: [] });
  await open();
  const models = modelRows(menu()!);
  // The running model's row shows its check in place of its number.
  expect(models.map((row) => row.querySelector(".ui-menu-shortcut")?.textContent ?? "✓")).toEqual(["1", "✓", "3", "4"]);
  const third = models[2]!;
  const name = third.querySelector(".acpmux-menu-label")!.textContent!;
  await act(async () => {
    menu()!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "3", bubbles: true }));
  });
  await settle();
  expect(sent.filter((entry) => entry.method === "model")).toHaveLength(1);
  expect(chipButton().getAttribute("title")).toContain(name);
});

test("Effort lists the model's levels and a pick sends it", async () => {
  const { sent } = await mount({ routes: [] });
  await open();
  const effort = await openSub("Effort");
  expect(itemsOf(effort)).toEqual(["Low", "Medium", "High"]);
  const high = [...effort.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
    (item) => item.textContent?.trim() === "High",
  )!;
  await act(async () => high.click());
  await settle();
  expect(sent).toEqual([{ method: "effort", value: "high" }]);
});

test("Account lists the routes that serve this chat and switches to one", async () => {
  const { sent, asked } = await mount({
    routes: [
      { id: "work", name: "Work Max", kind: "direct-subscription", serves: true },
      { id: "sr", name: "Subrouter", kind: "subrouter", serves: true },
      { id: "openai", name: "OpenAI key", kind: "custom-openai", serves: false },
    ],
    active: { routeId: "sr", scope: "chat" },
    family: "claude",
  });
  await open();
  expect(asked).toEqual(["s1"]);
  expect(itemsOf(menu()!).some((row) => row === "AccountSubrouter")).toBe(true);
  const account = await openSub("Account");
  expect(itemsOf(account)).toEqual(["CLI login", "Work Max", "Subrouter"]);
  const checked = account.querySelector('[role="menuitemradio"][aria-checked="true"]');
  expect(checked?.textContent?.replace("✓", "").trim()).toBe("Subrouter");
  const work = [...account.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
    (item) => item.textContent?.trim() === "Work Max",
  )!;
  await act(async () => work.click());
  await settle();
  expect(sent).toEqual([{ method: "route", value: "work" }]);
});

test("with no routes, Account offers the CLI login and says how to add one", async () => {
  await mount({ routes: [] });
  await open();
  const account = await openSub("Account");
  // `cmux route` is gone (Leo, 2026-10-21): an account is a route file, so the note names its folder.
  expect(itemsOf(account)).toEqual(["CLI login", "Add accounts as route files in ~/.config/cmux/routes"]);
  expect(account.textContent).not.toContain("cmux route");
});

test("the rail lists Starred, then each harness; a harness's tab lists its models in place", async () => {
  // Starred shows once a model is starred (in the full picker); then it leads the rail.
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const claude = BUNDLED_MODEL_CATALOG.harnesses.find((harness) => harness.id === "claude")!;
  const starred = claude.models.find((model) => /haiku/i.test(model.id))!.id;
  dom.window.localStorage.setItem("cmux.model-picker.favorites", JSON.stringify([starred]));
  await mount({ routes: [] });
  await open();
  const labels = railTabs().map((tab) => tab.getAttribute("aria-label"));
  expect(labels[0]).toBe("Starred");
  expect(labels).toContain("Claude Code");
  expect(labels).toContain("Codex");
  const codex = railTabs().find((tab) => tab.getAttribute("aria-label") === "Codex")!;
  await act(async () => codex.click());
  await settle();
  // The menu stays open on the other harness's models.
  expect(menu()).not.toBeNull();
  const names = modelNames(menu()!);
  expect(names.length).toBeGreaterThan(0);
  expect(names.every((name) => !/opus|sonnet|haiku/i.test(name))).toBe(true);
  // Effort and Account are the chat's: another harness's tab shows neither.
  expect(itemsOf(menu()!).some((row) => row?.startsWith("Account") || row?.startsWith("Effort"))).toBe(false);
});

test("without a starred model the rail starts at the harnesses", async () => {
  await mount({ routes: [] });
  await open();
  expect(railTabs()[0]?.getAttribute("aria-label")).toBe("Claude Code");
});

test("More models is a submenu: the harness's other models, then Add harness…", async () => {
  const { added } = await mount({ routes: [] });
  await open();
  const top = modelNames(menu()!);
  const more = await openSub("More models");
  const rows = itemsOf(more);
  expect(rows.at(-1)).toBe("Add harness…");
  expect(rows.length).toBeGreaterThan(1);
  // Only models the top list does not already show.
  expect(rows.slice(0, -1).some((row) => top.includes(row ?? ""))).toBe(false);
  expect(doc().querySelector(".acpmux-mp")).toBeNull();
  const add = [...more.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent?.trim() === "Add harness…",
  )!;
  await act(async () => add.click());
  await settle();
  expect(added).toEqual(["add"]);
});

test("typing filters the models in place, across harnesses, with no search field", async () => {
  await mount({ routes: [] });
  await open();
  for (const letter of "hai") await key(letter);
  await settle();
  expect(menu()).not.toBeNull();
  expect(doc().querySelector(".acpmux-mp")).toBeNull();
  expect(menu()!.querySelector("input")).toBeNull();
  const names = modelNames(menu()!);
  expect(names.length).toBeGreaterThan(0);
  expect(names.every((name) => name.toLowerCase().includes("hai"))).toBe(true);
  await key("Backspace");
  await key("Backspace");
  await key("Backspace");
  await settle();
  expect(modelNames(menu()!).some((name) => name.toLowerCase().includes("opus"))).toBe(true);
});

// Review of #22005: the composer re-renders while the menu is open, keys keep reaching the menu
// while typing unmounts rows, digits narrow a filter, and the rail is no row of the list.
test("the rail tab and the typed filter survive the composer re-rendering", async () => {
  const { rerender } = await mount({ routes: [] });
  await open();
  const codex = railTabs().find((tab) => tab.getAttribute("aria-label") === "Codex")!;
  await act(async () => codex.click());
  await settle();
  const names = modelNames(menu()!);
  await rerender();
  await settle();
  expect(modelNames(menu()!)).toEqual(names);
  for (const letter of "hai") await key(letter);
  await rerender();
  await settle();
  expect(menu()!.querySelector(".ui-menu-group-label")?.textContent).toBe("“hai”");
});

test("typing keeps keyboard focus in the menu when the focused row goes away", async () => {
  await mount({ routes: [] });
  await open();
  const effort = [...menu()!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.startsWith("Effort"),
  )!;
  await act(async () => effort.focus());
  const typeAt = (value: string) =>
    act(async () => {
      const target = (doc().activeElement as HTMLElement | null) ?? doc().body;
      target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: value, bubbles: true }));
    });
  await typeAt("h");
  await settle();
  expect(menu()!.contains(doc().activeElement)).toBe(true);
  await typeAt("a");
  await settle();
  expect(menu()!.querySelector(".ui-menu-group-label")?.textContent).toBe("“ha”");
});

// Greptile on #22005: the composer hands the menu a new families object on every render, and a
// streaming reply re-renders it. A row the keyboard moved to stays focused, so Enter picks it.
test("a filtered row the keyboard moved to keeps focus as the composer re-renders", async () => {
  const { rerender } = await mount({ routes: [] });
  await open();
  for (const letter of "gpt") await key(letter);
  await settle();
  const rows = modelRows(menu()!);
  expect(rows.length).toBeGreaterThan(1);
  await act(async () => rows[1]!.focus());
  const name = rows[1]!.querySelector(".acpmux-menu-label")?.textContent;
  await rerender();
  await settle();
  expect((doc().activeElement as HTMLElement | null)?.querySelector(".acpmux-menu-label")?.textContent).toBe(name);
});

test("while filtering, a digit narrows the list instead of picking a row", async () => {
  const { sent } = await mount({ routes: [] });
  await open();
  for (const letter of "gpt 5") await key(letter);
  await settle();
  expect(menu()).not.toBeNull();
  expect(sent.filter((entry) => entry.method === "model")).toHaveLength(0);
  expect(menu()!.querySelector(".ui-menu-group-label")?.textContent).toBe("“gpt 5”");
});

// A digit narrows a filter, so the filtered rows show no number to press.
test("while filtering, the rows show no number keys", async () => {
  await mount({ routes: [] });
  await open();
  for (const letter of "o") await key(letter);
  await settle();
  const rows = [...menu()!.querySelectorAll<HTMLElement>(".acpmux-quick-item")];
  expect(rows.length).toBeGreaterThan(0);
  expect(rows.filter((row) => row.querySelector(".ui-menu-shortcut"))).toHaveLength(0);
});

test("the rail's tabs are not rows of the menu", async () => {
  await mount({ routes: [] });
  await open();
  expect(railTabs().length).toBeGreaterThan(1);
  expect(railTabs().every((tab) => !(tab.getAttribute("role") ?? "").startsWith("menuitem"))).toBe(true);
  // Right moves to the next harness's tab.
  await key("ArrowRight");
  await settle();
  expect(railTabs().findIndex((tab) => tab.getAttribute("aria-pressed") === "true")).toBe(1);
});

// Leo 2026-10-20: Fast mode lives in one place, a checkbox row after Account, never a radio group
// inside Effort › and never a bolt in the composer.
test("Fast mode is a checkbox row after Account, checked from the session, and a click toggles it", async () => {
  const { sent } = await mount({ routes: [] }, { fast: true });
  expect(host.querySelector(".acpmux-fast")).toBeNull();
  await open();
  const rows = itemsOf(menu()!);
  expect(rows.at(-1)).toBe("Fast mode");
  expect(rows.findIndex((row) => row?.startsWith("Account"))).toBeLessThan(rows.length - 1);
  const fast = () => menu()!.querySelector<HTMLElement>('.acpmux-quick-fast[role="menuitemcheckbox"]')!;
  expect(fast()).not.toBeNull();
  expect(fast().getAttribute("aria-checked")).toBe("false");
  const effort = await openSub("Effort");
  expect(effort.textContent).not.toMatch(/fast/i);
  expect(itemsOf(effort)).toEqual(["Low", "Medium", "High"]);
  await act(async () => fast().click());
  await settle();
  expect(sent).toEqual([{ method: "effort", value: "on" }]);
  // The session confirms it: the row is checked, and the button still names no Fast.
  if (!menu()) await open();
  expect(fast().getAttribute("aria-checked")).toBe("true");
  expect(chipButton().textContent).not.toMatch(/fast/i);
  await act(async () => fast().click());
  await settle();
  expect(sent).toEqual([
    { method: "effort", value: "on" },
    { method: "effort", value: "off" },
  ]);
});

test("a model with no fast option has no Fast mode row", async () => {
  await mount({ routes: [] });
  await open();
  expect(menu()!.querySelector(".acpmux-quick-fast")).toBeNull();
  expect(itemsOf(menu()!).includes("Fast mode")).toBe(false);
});

// Leo 2026-10-20: the button read "claude-opus-5-5" and "Reasoning". A model the catalog does not
// name is read from its id, and an effort the pane cannot resolve draws no word at all.
test("a raw model id is named as people say it, and an unresolved effort draws no Reasoning", async () => {
  await mount({ routes: [] }, { model: "claude-opus-9-1", effort: "default" });
  const text = chipButton().textContent ?? "";
  expect(text).toContain("Opus 9.1");
  expect(text).not.toContain("claude-opus-9-1");
  expect(text).not.toContain("Reasoning");
  expect(host.querySelector(".acpmux-model-detail")).toBeNull();
});

test("a switch acpmux refuses is named on the Account row", async () => {
  const { sent } = await mount(
    { routes: [{ id: "work", name: "Work Max", serves: true }], family: "claude" },
    { refuse: true },
  );
  await open();
  const account = await openSub("Account");
  const work = [...account.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
    (item) => item.textContent?.trim() === "Work Max",
  )!;
  await act(async () => work.click());
  await settle();
  expect(sent).toEqual([{ method: "route", value: "work" }]);
  await open();
  expect(itemsOf(menu()!).some((row) => row === "AccountCouldn’t switch account")).toBe(true);
});

test("Cmd-Ctrl-M over the compact menu opens the full picker in its place", async () => {
  await mount({ routes: [] });
  await open();
  expect(menu()).not.toBeNull();
  await act(async () => {
    dom.window.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true, bubbles: true }),
    );
  });
  await settle();
  expect(doc().querySelector(".acpmux-mp")).not.toBeNull();
  expect(menu()).toBeNull();
});

// Leo 2026-10-19: a started chat's menu drew a rail of its one harness, then offered Add harness….
// Once a chat has a message its harness is fixed, as in Claude Code: the compact menu lists its
// models with no rail, and More models opens the full picker, which has no rail either.
test("a started chat's compact menu has no harness rail and no Add harness…", async () => {
  const { added } = await mount({ routes: [] }, { turnCount: 1 });
  await open();
  expect(menu()!.querySelector(".acpmux-quick-rail")).toBeNull();
  expect(modelNames(menu()!).length).toBeGreaterThan(0);
  const more = [...menu()!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.startsWith("More models"),
  )!;
  await act(async () => more.click());
  await settle();
  const full = doc().querySelector<HTMLElement>(".acpmux-mp")!;
  expect(full).not.toBeNull();
  expect(full.querySelector(".acpmux-mp-rail-scroll")).toBeNull();
  expect(full.querySelector(".acpmux-mp-add-harness")).toBeNull();
  expect(added).toEqual([]);
});

// Lucas 2026-10-22: the menu opens above its chip, so a provider tab with more or fewer rows than
// the last one moved the menu's top edge, and the rail tabs moved out from under the pointer. The
// list holds the tallest tab's rows and separators unseen for the whole opening: every tab fits in
// that space, the tallest fills it, and it does not change as tabs change.
test("every rail tab fits in the same list height, the tallest tab's, for the whole opening", async () => {
  await mount({ routes: [] }, { fast: true });
  await open();
  const body = () => menu()!.querySelector<HTMLElement>(".acpmux-quick-body")!;
  const spacer = () => {
    const node = body().querySelector<HTMLElement>(".acpmux-quick-spacer");
    expect(node, "the list holds the tallest tab's height").not.toBeNull();
    expect(node!.getAttribute("aria-hidden")).toBe("true");
    return {
      rows: node!.querySelectorAll(".acpmux-quick-item").length,
      separators: node!.querySelectorAll(".ui-separator").length,
    };
  };
  const shown = () => ({
    rows: body().querySelectorAll('[role^="menuitem"]').length,
    separators: body().querySelectorAll('[role="separator"]').length,
  });
  const held = spacer();
  const tabs = railTabs().map((tab) => tab.getAttribute("aria-label")!);
  expect(tabs.length).toBeGreaterThan(1);
  const extents: { rows: number; separators: number }[] = [];
  for (const name of tabs) {
    const tab = railTabs().find((each) => each.getAttribute("aria-label") === name)!;
    await act(async () => tab.click());
    await settle();
    expect(spacer(), `the held height on ${name}`).toEqual(held);
    const extent = shown();
    expect(extent.rows, `${name}'s rows`).toBeLessThanOrEqual(held.rows);
    expect(extent.separators, `${name}'s separators`).toBeLessThanOrEqual(held.separators);
    extents.push(extent);
  }
  // The space is the tallest tab's, not more.
  expect(Math.max(...extents.map((each) => each.rows))).toBe(held.rows);
  expect(Math.max(...extents.map((each) => each.separators))).toBe(held.separators);
  // The chat's own tab (Effort, Account, Fast mode) is taller than another harness's.
  expect(new Set(extents.map((each) => each.rows)).size).toBeGreaterThan(1);
  // Typing keeps the same height too.
  await key("o");
  expect(spacer()).toEqual(held);
});
