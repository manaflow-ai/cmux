// Leo 2026-10-18: the model chip opens a short Claude Code style menu (the Debug Settings choice
// `agent.modelMenu`, compact by default in the app): numbered models, Effort and Account beside
// their rows, and More models for the full picker. Account lists the acpmux routes that serve the
// chat and switches the chat's route. The real composer, catalog and menu, in JSDOM.
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
async function mount(listed: unknown, options: { fast?: boolean; refuse?: boolean } = {}) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  const { ChatAccountsContext, readChatAccounts } = await import("../src/agent-session/acpmux/chatAccounts");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  setComposerSettings({ modelMenu: "compact" });
  const acpmux: Snapshot["catalog"] = BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
    id: harness.id,
    name: harness.name,
    family: harness.families[0],
    models: harness.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
  const sent: Sent[] = [];
  const asked: string[] = [];
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
    const [state, setState] = useState({ model: "claude-opus-5-5", effort: "medium", fast: "off" });
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
        turnCount: 0,
        configOptions: [
          {
            id: "effort",
            name: "Effort",
            category: "thought_level",
            currentValue: state.effort,
            options: ["low", "medium", "high"].map((value) => ({ value, name: value })),
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
      />
    );
  }
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <ChatAccountsContext.Provider value={accounts}>
          <Host />
        </ChatAccountsContext.Provider>
      </QueryClientProvider>,
    );
  });
  return { sent, asked };
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 20)));
const chipButton = () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!;
const menu = () => doc().querySelector<HTMLElement>(".acpmux-quick-menu");
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
  expect(rows.at(-1)).toBe("More models");
});

test("a number key picks that model in place", async () => {
  const { sent } = await mount({ routes: [] });
  await open();
  const models = [...menu()!.querySelectorAll<HTMLElement>('[role="menuitemradio"]')];
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
  expect(itemsOf(account)).toEqual(["CLI login", "Add accounts with cmux route add"]);
});

test("More models opens the full picker, and typing in the menu searches it", async () => {
  await mount({ routes: [] });
  await open();
  const more = [...menu()!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent?.trim() === "More models",
  )!;
  await act(async () => more.click());
  await settle();
  expect(doc().querySelector(".acpmux-mp")).not.toBeNull();
  expect(menu()).toBeNull();
  await act(async () => chipButton().click());
  await settle();
  await open();
  await act(async () => {
    menu()!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "g", bubbles: true }));
  });
  await settle();
  const search = doc().querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]');
  expect(search?.value).toBe("g");
});

// Review of #21853: the bolt leaves a narrow row, so fast mode must stay reachable from the menu.
test("Effort also offers fast mode", async () => {
  const { sent } = await mount({ routes: [] }, { fast: true });
  await open();
  const effort = await openSub("Effort");
  expect(effort.textContent).toContain("Fast Mode");
  const on = [...effort.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].find(
    (item) => item.textContent?.replace("✓", "").trim() === "On",
  )!;
  await act(async () => on.click());
  await settle();
  expect(sent).toEqual([{ method: "effort", value: "on" }]);
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
