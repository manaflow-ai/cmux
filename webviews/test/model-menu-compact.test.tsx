// Leo 2026-10-18: the model chip opens a short Claude Code style menu. Since Leo 2026-10-20 it is
// every composer's one model button ("Opus 5.5  Medium"): no effort chip and no bolt. Since Lucas
// 2026-11-03 a menu with a harness rail is columns (QuickModelColumns): the rail (Starred, then each
// harness), the tab's models, then the shown model's settings (Effort levels, Fast as a switch). The
// account is an avatar in the search row whose card lists the acpmux routes that serve the chat and
// switches the chat's route. A started chat or a machine profile has no rail and keeps the list menu.
// The real composer, catalog and menu, in JSDOM.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import type { UpdateOffer } from "../src/agent-session/acpmux/harnessHealthNoticeModel";
import { DEFAULT_COMPOSER, setComposerSettings } from "../src/agent-session/acpmux/composerSettings";
import { teardownDom } from "./support/domTeardown";

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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  setComposerSettings(DEFAULT_COMPOSER);
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu, .acpmux-cols")) popup.remove();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
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
    /** A custom harness whose only icon is acpmux's generic glyph (no brand mark behind it). */
    glyphHarness?: boolean;
    update?: UpdateOffer;
    addAccount?: (account: Record<string, unknown>) => Promise<void>;
  } = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { UpdateOfferContext } = await import("../src/agent-session/acpmux/harnessHealthNoticeModel");
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
    ...(options.glyphHarness
      ? [
          {
            id: "glyph-harness",
            name: "Glyph harness",
            iconSpec: { kind: "glyph", name: "terminal", source: "default" },
            models: [{ id: "glyph-model", name: "Glyph model" }],
          },
        ]
      : []),
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
    ...(options.addAccount ? { add: options.addAccount } : {}),
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
const chipButton = () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!;
/// The columns menu (a popover), there while a menu with a rail is open.
const cols = () => doc().querySelector<HTMLElement>(".acpmux-cols");
/// The open model menu: the columns, or the list menu of a chat with no rail.
const menu = () => doc().querySelector<HTMLElement>(".acpmux-cols, .acpmux-quick-menu");
/// The model rows: the columns' options, or the list menu's radio items.
const modelRows = (popup: HTMLElement) => [
  ...popup.querySelectorAll<HTMLElement>('.acpmux-cols-row[role="option"], .acpmux-quick-item[role="menuitemradio"]'),
];
const nameOf = (row: Element) => row.querySelector(".acpmux-cols-name, .acpmux-menu-label")?.textContent ?? "";
const modelNames = (popup: HTMLElement) => modelRows(popup).map(nameOf);
/// The settings column: the shown model's effort levels (highest first), then Fast.
const tune = () => cols()!.querySelector<HTMLElement>(".acpmux-cols-tune")!;
const levels = () => [...tune().querySelectorAll<HTMLElement>('[role="radio"]')];
const fastSwitch = () => tune().querySelector<HTMLElement>('[role="switch"]');
/// The harness rail's tabs (Add harness… is a button, not a tab).
const railTabs = () => [...cols()!.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]')];
const railTab = (name: string) => railTabs().find((tab) => tab.getAttribute("aria-label") === name)!;
const captions = () =>
  [...cols()!.querySelectorAll<HTMLElement>('[role="listbox"] .acpmux-cols-caption')].map(
    (caption) => caption.textContent,
  );
/// The menu's search field.
const field = () =>
  menu()?.querySelector<HTMLInputElement>(".acpmux-cols-search input, .acpmux-quick-search input") ?? null;
/// Types `text` into the search field as the browser does (its value, then an input event).
const typeIn = (text: string) =>
  act(async () => {
    const input = field()!;
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, text);
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
/// A key pressed in the search field, which keeps the keyboard; returns the event.
const key = async (value: string) => {
  const event = new dom.window.KeyboardEvent("keydown", {
    key: value,
    bubbles: true,
    cancelable: true,
  });
  await act(async () => {
    field()!.dispatchEvent(event);
  });
  return event;
};
const click = async (target: HTMLElement) => {
  await act(async () => target.click());
  await settle();
};

async function open() {
  await act(async () => chipButton().click());
  await settle();
}

/// Opens the avatar's account card: the face of the account in use, then the harness's other ones.
async function openCard() {
  const avatar = cols()!.querySelector<HTMLElement>("button.acpmux-cols-profile");
  expect(avatar, "the account avatar").not.toBeNull();
  await click(avatar!);
  const card = cols()!.querySelector<HTMLElement>(".acpmux-cols-card");
  expect(card, "the account card").not.toBeNull();
  return card!;
}
const cardName = (card: HTMLElement) => card.querySelector(".acpmux-cols-card-name")?.textContent;
/// The card's other accounts, without Add account….
const cardRows = (card: HTMLElement) => [
  ...card.querySelectorAll<HTMLElement>('.acpmux-cols-card-list [role="button"]:not(.acpmux-cols-add)'),
];
const cardRow = (card: HTMLElement, name: string) => cardRows(card).find((row) => nameOf(row) === name)!;

test("the compact chip names the model and its effort, and a click opens the short menu", async () => {
  await mount({ routes: [] });
  expect(chipButton().textContent).toContain("Opus 5.5");
  expect(chipButton().textContent).toContain("Medium");
  // No separate effort chip: Effort is a column of the menu.
  expect(host.querySelector(".acpmux-effort")).toBeNull();
  await open();
  expect(cols()).not.toBeNull();
  expect(chipButton().getAttribute("aria-expanded")).toBe("true");
  expect(cols()!.querySelector(".ui-menu-group-label")).toBeNull();
  expect(doc().querySelector(".acpmux-mp")).toBeNull();
  // The running model's levels, highest first, its own checked.
  expect(levels().map(nameOf)).toEqual(["High", "Medium", "Low"]);
  expect(levels().find((level) => level.getAttribute("aria-checked") === "true")?.textContent).toContain("Medium");
  // The account is the avatar in the search row.
  expect(cols()!.querySelector("button.acpmux-cols-profile")?.getAttribute("aria-label")).toContain("Account");
  // Claude Code's order: the tab's models, then its Legacy models in the same column.
  expect(captions()).toEqual(["Claude Code", "Legacy models"]);
});

test("a number key picks that model and closes the menu", async () => {
  const { sent } = await mount({ routes: [] });
  await open();
  const name = modelNames(cols()!)[2]!;
  const event = await key("3");
  await settle();
  expect(event.defaultPrevented).toBe(true);
  expect(sent.filter((entry) => entry.method === "model")).toHaveLength(1);
  expect(chipButton().getAttribute("title")).toContain(name);
  expect(cols()).toBeNull();
});

test("Effort lists the model's levels and a pick sends it", async () => {
  const { sent } = await mount({ routes: [] });
  await open();
  expect(levels().map(nameOf)).toEqual(["High", "Medium", "Low"]);
  await click(levels().find((level) => nameOf(level) === "High")!);
  expect(sent).toEqual([{ method: "effort", value: "high" }]);
  // A click applies at once and the menu stays open on the new level.
  expect(cols()).not.toBeNull();
  expect(levels().find((level) => level.getAttribute("aria-checked") === "true")?.textContent).toContain("High");
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
  expect(cols()!.querySelector("button.acpmux-cols-profile")?.getAttribute("aria-label")).toBe(
    "Claude Code · Account: Subrouter",
  );
  const card = await openCard();
  // The card's head is the account in use; its list, the others that serve the chat.
  expect(cardName(card)).toBe("Subrouter");
  expect(cardRows(card).map(nameOf)).toEqual(["CLI login", "Work Max"]);
  await click(cardRow(card, "Work Max"));
  expect(sent).toEqual([{ method: "route", value: "work" }]);
});

test("Account offers Cmux for this harness and switches the route without switching harness", async () => {
  const { sent } = await mount({
    routes: [
      { id: "cmux", name: "Cmux", kind: "cmux-router", serves: true },
      { id: "other", name: "Other family", kind: "cmux-router", serves: false },
    ],
    family: "claude",
  });
  await open();
  const card = await openCard();
  expect(cardName(card)).toBe("CLI login");
  expect(cardRows(card).map(nameOf)).toEqual(["Cmux"]);
  await click(cardRow(card, "Cmux"));
  expect(sent).toEqual([{ method: "route", value: "cmux" }]);
});

test("Account lists this harness's direct accounts and Cmux providers without unrelated transport variants", async () => {
  const { sent } = await mount({
    routes: [
      { id: "work", name: "Work Max", kind: "direct-subscription", serves: true },
      { id: "key", name: "Work API key", kind: "direct-api-key", serves: true },
      { id: "codex", name: "Codex account", kind: "direct-subscription", serves: false },
      ...["subrouter", "cliproxyapi", "custom-anthropic", "custom-openai", "local-coderouter", "cmux-router"].map(
        (kind) => ({ id: kind, name: kind, kind, serves: true }),
      ),
      { id: "legacy", name: "Unbound legacy route", serves: true },
    ],
    family: "claude",
  });
  await open();
  const card = await openCard();
  expect(cardName(card)).toBe("CLI login");
  expect(cardRows(card).map(nameOf)).toEqual(["Work Max", "Work API key", "local-coderouter", "cmux-router"]);
  await click(cardRow(card, "Work API key"));
  expect(sent).toEqual([{ method: "route", value: "key" }]);
});

test("Account preserves the selected legacy route while hiding other unknown routes", async () => {
  await mount({
    routes: [
      { id: "bound", name: "Selected account", serves: true },
      { id: "other", name: "Other legacy route", serves: true },
      { id: "proxy", name: "Proxy transport", kind: "subrouter", serves: true },
    ],
    active: { routeId: "bound", scope: "chat" },
  });
  await open();
  expect(cols()!.querySelector("button.acpmux-cols-profile")?.getAttribute("aria-label")).toContain("Selected account");
  const card = await openCard();
  expect(cardName(card)).toBe("Selected account");
  expect(cardRows(card).map(nameOf)).toEqual(["CLI login"]);
});

// Leo 2026-10-29: "Why the fuck did you remove the fucking account switcher?" #27151 renamed the
// composer's Account row to Provider. The account switcher stays; Cmux routers in it say Provider,
// so Leo's "change provider to cmux" still reads as a provider choice.
test("the composer keeps its Account switcher, with Cmux routers named Provider", async () => {
  const { sent } = await mount({
    routes: [
      { id: "work", name: "Work Max", kind: "direct-subscription", serves: true },
      { id: "cmux", name: "Cmux", kind: "cmux-router", serves: true },
    ],
    family: "claude",
  });
  await open();
  const card = await openCard();
  expect(cardRows(card).map(nameOf)).toEqual(["Work Max", "Cmux"]);
  expect(cardRow(card, "Cmux").querySelector(".acpmux-cols-detail")?.textContent).toBe("Provider");
  expect(cardRow(card, "Work Max").querySelector(".acpmux-cols-detail")).toBeNull();
  await click(cardRow(card, "Work Max"));
  expect(sent).toEqual([{ method: "route", value: "work" }]);
});

test("with no routes, Account offers only the CLI login until a family is known", async () => {
  await mount({ routes: [] });
  await open();
  const card = await openCard();
  expect(cardName(card)).toBe("CLI login");
  expect(cardRows(card)).toHaveLength(0);
  expect(card.textContent).not.toContain("cmux route");
});

test("the rail lists Starred, then each harness; a harness's tab lists its models in place", async () => {
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
  await click(railTab("Codex"));
  // The menu stays open on the other harness's models.
  expect(cols()).not.toBeNull();
  expect(railTab("Codex").getAttribute("aria-selected")).toBe("true");
  const names = modelNames(cols()!);
  expect(names.length).toBeGreaterThan(0);
  expect(names.every((name) => !/opus|sonnet|haiku/i.test(name))).toBe(true);
  // The avatar follows the shown harness: Codex's account, never the chat's.
  expect(cols()!.querySelector("button.acpmux-cols-profile")?.getAttribute("aria-label")).toMatch(/^Codex · /);
});

test("a row's star stars and unstars its model, and ⌘D is left to Split Right", async () => {
  await mount({ routes: [] });
  await open();
  const row = modelRows(cols()!)[0]!;
  const name = nameOf(row);
  const star = () => row.querySelector<HTMLButtonElement>(".acpmux-cols-star")!;
  // The star says which model it stars, and names no key.
  expect(star().getAttribute("aria-label")).toContain(name);
  expect(star().hasAttribute("aria-keyshortcuts")).toBe(false);
  expect(star().title).not.toContain("⌘D");
  expect(star().getAttribute("aria-pressed")).toBe("false");
  // ⌘D is cmux's Split Right: the open menu neither stars with it nor keeps it from the app.
  const commandD = new dom.window.KeyboardEvent("keydown", {
    key: "d",
    metaKey: true,
    bubbles: true,
    cancelable: true,
  });
  await act(async () => {
    field()!.dispatchEvent(commandD);
  });
  await settle();
  expect(commandD.defaultPrevented, "the menu took ⌘D").toBe(false);
  expect(star().getAttribute("aria-pressed")).toBe("false");
  await click(star());
  expect(star().getAttribute("aria-pressed")).toBe("true");
  expect(cols(), "the star closed the menu").not.toBeNull();
  await click(star());
  expect(star().getAttribute("aria-pressed")).toBe("false");
});

test("every harness tab on the rail is a mark with no visible text, its name only its label", async () => {
  // Leo 2026-10-31: "NOBODY FUCKING ASKED FOR THE HARNESSES TO HAVE FUCKING LABELED FUCKING TEXT ON
  // THEM THAT'S THE POINT". A glyph-only harness (no brand mark behind it) draws its initial.
  const { rememberHarnessIcons } = await import("../src/agent-session/shared/harnessIcons");
  rememberHarnessIcons([{ id: "glyph-harness", iconSpec: { kind: "glyph", name: "terminal", source: "default" } }]);
  await mount({ routes: [] }, { glyphHarness: true });
  await open();
  const tabs = railTabs();
  expect(tabs.map((tab) => tab.getAttribute("aria-label"))).toContain("Glyph harness");
  for (const tab of tabs) {
    const name = tab.getAttribute("aria-label");
    // The name is the tab's label and tooltip, never text on the tab.
    expect(tab.title, `${name}`).toContain(name!);
    // Its mark: a symbol, the star, or the name's initial.
    expect(tab.querySelector(".agent-mark, svg, .acpmux-cols-initial"), `${name}: no mark`).not.toBeNull();
    expect(
      tab.textContent!.replace(/\s/g, "").length,
      `${name}: visible text "${tab.textContent}"`,
    ).toBeLessThanOrEqual(1);
  }
  expect(railTab("Glyph harness").querySelector(".acpmux-cols-initial")?.textContent).toBe("G");
  const add = cols()!.querySelector<HTMLElement>(".acpmux-cols-tab-add")!;
  expect(add.getAttribute("aria-label")).toBe("Add harness…");
  expect(add.textContent).toBe("");
});

// The columns' rail always leads with Starred, also before anything is starred (QuickModelColumns
// STARRED_TAB): an empty tab that says so. The menu still opens on the chat's harness.
test("without a starred model the rail leads with an empty Starred tab and opens on the harness", async () => {
  await mount({ routes: [] });
  await open();
  expect(railTabs()[0]?.getAttribute("aria-label")).toBe("Starred");
  expect(railTabs()[1]?.getAttribute("aria-label")).toBe("Claude Code");
  expect(railTab("Claude Code").getAttribute("aria-selected")).toBe("true");
  await click(railTab("Starred"));
  expect(modelRows(cols()!)).toHaveLength(0);
  expect(cols()!.querySelector('[role="listbox"] .acpmux-cols-note')?.textContent).toBe("No starred models");
});

test("the compact picker has no unrequested Profile row", async () => {
  await mount({ routes: [] });
  await open();
  expect(cols()!.textContent).not.toMatch(/\bProfile\b/);
  expect(cols()!.querySelector('[aria-label*="Profile"]')).toBeNull();
});

test("machine profiles stay out of the harness rail", async () => {
  await mount({ routes: [] }, { folderProfile: true });
  await open();
  const labels = railTabs().map((tab) => tab.getAttribute("aria-label"));
  expect(labels).toContain("Claude Code");
  expect(labels).toContain("Codex");
  expect(labels).not.toContain("Build machine");
});

test("the current machine profile keeps its compact model list without a rail", async () => {
  await mount({ routes: [] }, { folderProfile: true, currentFolder: true });
  await open();
  expect(cols()).toBeNull();
  expect(menu()!.querySelector(".acpmux-quick-rail")).toBeNull();
  expect(modelNames(menu()!)).toContain("Machine model");
});

// More models is no submenu now: the Legacy models follow the tab's own under their caption.
test("Add harness… is the last item in the harness strip, and Legacy models sit under the tab's own", async () => {
  const { added } = await mount({ routes: [] });
  await open();
  const listbox = cols()!.querySelector<HTMLElement>('[role="listbox"]')!;
  const children = [...listbox.children];
  const legacy = children.findIndex((child) => child.textContent === "Legacy models");
  expect(legacy).toBeGreaterThan(0);
  const top = children
    .slice(0, legacy)
    .filter((child) => child.matches('[role="option"]'))
    .map(nameOf);
  const more = children
    .slice(legacy)
    .filter((child) => child.matches('[role="option"]'))
    .map(nameOf);
  expect(top.length).toBeGreaterThan(0);
  expect(more.length).toBeGreaterThan(0);
  // Only models the top list does not already show.
  expect(more.some((name) => top.includes(name))).toBe(false);
  expect(listbox.textContent).not.toContain("Add harness…");
  expect(doc().querySelector(".acpmux-mp")).toBeNull();
  const rail = cols()!.querySelector<HTMLElement>(".acpmux-cols-rail")!;
  const add = rail.lastElementChild as HTMLElement;
  expect(add.classList.contains("acpmux-cols-tab-add")).toBe(true);
  expect(add.getAttribute("aria-label")).toBe("Add harness…");
  await click(add);
  expect(added).toEqual(["add"]);
  expect(cols()).toBeNull();
});

test("typing filters the models in place, across harnesses, in the search field", async () => {
  await mount({ routes: [] });
  await open();
  await typeIn("hai");
  await settle();
  expect(cols()).not.toBeNull();
  expect(doc().querySelector(".acpmux-mp")).toBeNull();
  expect(field()?.value).toBe("hai");
  const names = modelNames(cols()!);
  expect(names.length).toBeGreaterThan(0);
  expect(names.every((name) => name.toLowerCase().includes("hai"))).toBe(true);
  expect(cols()!.querySelectorAll(".acpmux-cols-group").length).toBeGreaterThan(0);
  await typeIn("");
  await settle();
  expect(modelNames(cols()!).some((name) => name.toLowerCase().includes("opus"))).toBe(true);
});

// Review of #22005: the composer re-renders while the menu is open, keys keep reaching the menu
// while typing unmounts rows, digits narrow a filter, and the rail is no row of the list.
test("the rail tab and the typed filter survive the composer re-rendering", async () => {
  const { rerender } = await mount({ routes: [] });
  await open();
  await click(railTab("Codex"));
  const names = modelNames(cols()!);
  await rerender();
  await settle();
  expect(modelNames(cols()!)).toEqual(names);
  expect(railTab("Codex").getAttribute("aria-selected")).toBe("true");
  await typeIn("hai");
  await rerender();
  await settle();
  expect(field()!.value).toBe("hai");
});

// A row never takes the keyboard (the slash menu's pattern): the search field keeps it while a
// click picks a model and while a filter replaces the rows. The pick has landed once the menu closes.
test("the search field keeps the keyboard as a click picks a model and typing replaces the rows", async () => {
  const { sent } = await mount({ routes: [] });
  await open();
  const row = modelRows(cols()!)[1]!;
  const name = nameOf(row);
  await click(row);
  // A click keeps the menu open and checks the picked row.
  expect(cols()).not.toBeNull();
  expect(row.getAttribute("aria-selected")).toBe("true");
  expect(doc().activeElement).toBe(field());
  await typeIn("ha");
  await settle();
  expect(cols()!.contains(doc().activeElement)).toBe(true);
  expect(doc().activeElement).toBe(field());
  expect(field()!.value).toBe("ha");
  // Escape first clears the search, then closes the menu.
  await key("Escape");
  await settle();
  expect(cols()).not.toBeNull();
  expect(field()!.value).toBe("");
  await key("Escape");
  await settle();
  expect(cols()).toBeNull();
  expect(sent.filter((entry) => entry.method === "model")).toHaveLength(1);
  expect(chipButton().getAttribute("title")).toContain(name);
});

// Lawrence 2026-10-22, on the model menu: "spacing + needs search". The menu opens with a search
// field that has the keyboard, and it finds models the way the full picker's search does.
test("the menu opens with a search field that has the keyboard", async () => {
  await mount({ routes: [] });
  await open();
  expect(field()).not.toBeNull();
  expect(field()!.placeholder).toBe("Type to search models");
  expect(doc().activeElement).toBe(field());
});

test("the search field filters every harness's models and heads each harness's matches with its name", async () => {
  await mount({ routes: [] });
  await open();
  await typeIn("gpt");
  await settle();
  const rows = modelRows(cols()!);
  expect(rows.length).toBeGreaterThan(0);
  expect(modelNames(cols()!).every((name) => name.toLowerCase().includes("gpt"))).toBe(true);
  // A wider live catalog can match GPT models from several harnesses; each row sits under its own.
  const tabs = new Set(railTabs().map((tab) => tab.getAttribute("aria-label")));
  for (const row of rows) {
    let heading = row.previousElementSibling;
    while (heading && !heading.classList.contains("acpmux-cols-group")) heading = heading.previousElementSibling;
    expect(tabs.has(heading?.textContent ?? "")).toBe(true);
  }
  // Lawrence, via Leo 2026-10-28: no tab stays lit while the matches are every harness's.
  expect(railTabs().filter((tab) => tab.getAttribute("aria-selected") === "true")).toHaveLength(0);
  await typeIn("");
  await settle();
  expect(modelNames(cols()!).some((name) => name.toLowerCase().includes("opus"))).toBe(true);
});

test("the search reads an effort word as the full picker does, and Enter lands the first match with it", async () => {
  const { sent } = await mount({ routes: [] });
  await open();
  await typeIn("opus 5.5 high");
  await settle();
  const rows = modelRows(cols()!);
  expect(rows.length).toBeGreaterThan(0);
  expect(nameOf(rows[0]!)).toBe("Opus 5.5");
  expect(rows[0]!.hasAttribute("data-hl")).toBe(true);
  await key("Enter");
  await settle();
  expect(cols()).toBeNull();
  expect(sent).toContainEqual({ method: "effort", value: "high" });
});

// Review of #27303: a started chat's menu has no harness rail, so its empty search never says to
// browse by harness.
test("a started chat's empty search says what to do without naming a harness list", async () => {
  await mount({ routes: [] }, { turnCount: 1 });
  await open();
  await typeIn("zzzz");
  await settle();
  expect(menu()!.querySelector(".acpmux-quick-note")?.textContent).toBe("No models match “zzzz”. Try part of a name.");
});

test("a started chat's search field filters its own models in place, without opening the full picker", async () => {
  await mount({ routes: [] }, { turnCount: 1 });
  await open();
  expect(field()).not.toBeNull();
  await typeIn("son");
  await settle();
  expect(doc().querySelector(".acpmux-mp")).toBeNull();
  const names = modelNames(menu()!);
  expect(names.length).toBeGreaterThan(0);
  expect(names.every((name) => /sonnet/i.test(name))).toBe(true);
});

// Greptile on #22005: the composer hands the menu a new families object on every render, and a
// streaming reply re-renders it. The row the arrows moved to stays highlighted, so Enter picks it.
test("a filtered row the arrows moved to stays highlighted as the composer re-renders, and Enter lands it", async () => {
  const { sent, rerender } = await mount({ routes: [] });
  await open();
  // The chat's own harness leads the matches; Enter on its second row lands it in this chat.
  await typeIn("opus");
  await settle();
  const rows = modelRows(cols()!);
  expect(rows.length).toBeGreaterThan(1);
  // The first group heading names the chat's harness (a row's tooltip is its name alone, 2026-11-11).
  expect(cols()!.querySelector(".acpmux-cols-group")?.textContent).toContain("Claude Code");
  const name = nameOf(rows[1]!);
  await key("ArrowDown");
  await settle();
  // The arrows only move the highlight: nothing lands until Enter.
  expect(sent).toEqual([]);
  const highlighted = () => cols()!.querySelector<HTMLElement>('[role="option"][data-hl]');
  expect(highlighted() && nameOf(highlighted()!)).toBe(name);
  await rerender();
  await settle();
  expect(highlighted() && nameOf(highlighted()!)).toBe(name);
  expect(field()!.getAttribute("aria-activedescendant")).toBe(highlighted()!.id);
  await key("Enter");
  await settle();
  expect(cols()).toBeNull();
  expect(sent.filter((entry) => entry.method === "model")).toHaveLength(1);
  expect(chipButton().getAttribute("title")).toContain(name);
});

test("while filtering, a digit narrows the list instead of picking a row", async () => {
  const { sent } = await mount({ routes: [] });
  await open();
  await typeIn("gpt ");
  const digit = await key("5");
  await settle();
  // The field types it: the menu neither takes the key nor lands a model.
  expect(digit.defaultPrevented).toBe(false);
  await typeIn("gpt 5");
  await settle();
  expect(cols()).not.toBeNull();
  expect(sent.filter((entry) => entry.method === "model")).toHaveLength(0);
  expect(field()!.value).toBe("gpt 5");
});

test("the rail's tabs are not rows of the model list, and the arrows reach them from the left", async () => {
  await mount({ routes: [] });
  await open();
  expect(railTabs().length).toBeGreaterThan(1);
  expect(railTabs().every((tab) => tab.getAttribute("role") === "tab")).toBe(true);
  expect(railTabs().every((tab) => !tab.closest('[role="listbox"]'))).toBe(true);
  const selected = () => railTabs().findIndex((tab) => tab.getAttribute("aria-selected") === "true");
  expect(selected()).toBe(1);
  // Left moves to the rail; Down there moves to the next harness's tab.
  await key("ArrowLeft");
  await settle();
  expect(cols()!.querySelector(".acpmux-cols-rail")!.hasAttribute("data-col-focus")).toBe(true);
  await key("ArrowDown");
  await settle();
  expect(selected()).toBe(2);
  expect(cols()).not.toBeNull();
});

// Leo 2026-10-20: Fast mode lives in one place, never a radio group inside Effort and never a bolt
// in the composer. In the columns it is a switch, the settings column's last row, after the levels.
test("Fast mode is a switch after the effort levels, on from the session, and a click toggles it", async () => {
  const { sent } = await mount({ routes: [] }, { fast: true });
  expect(host.querySelector(".acpmux-fast")).toBeNull();
  await open();
  const rows = [...tune().querySelectorAll<HTMLElement>('[role="radio"], [role="switch"]')];
  expect(rows.map(nameOf)).toEqual(["High", "Medium", "Low", "Fast"]);
  expect(fastSwitch()!.getAttribute("aria-checked")).toBe("false");
  expect(fastSwitch()!.querySelector(".acpmux-cols-switch")!.hasAttribute("data-on")).toBe(false);
  await click(fastSwitch()!);
  expect(sent).toEqual([{ method: "effort", value: "on" }]);
  // The session confirms it: the switch is on, the menu still open, and the button names no Fast.
  expect(cols()).not.toBeNull();
  expect(fastSwitch()!.getAttribute("aria-checked")).toBe("true");
  expect(fastSwitch()!.querySelector(".acpmux-cols-switch")!.hasAttribute("data-on")).toBe(true);
  expect(chipButton().textContent).not.toMatch(/fast/i);
  await click(fastSwitch()!);
  expect(sent).toEqual([
    { method: "effort", value: "on" },
    { method: "effort", value: "off" },
  ]);
});

test("a model with no fast option has no Fast mode row", async () => {
  await mount({ routes: [] });
  await open();
  expect(fastSwitch()).toBeNull();
  expect(tune().textContent).not.toContain("Fast");
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

test("a switch acpmux refuses is named in the account card", async () => {
  const { sent } = await mount(
    {
      routes: [{ id: "work", name: "Work Max", kind: "direct-subscription", serves: true }],
      family: "claude",
    },
    { refuse: true },
  );
  await open();
  await click(cardRow(await openCard(), "Work Max"));
  expect(sent).toEqual([{ method: "route", value: "work" }]);
  if (!cols()) await open();
  const card = await openCard();
  expect(card.querySelector(".acpmux-cols-note")?.textContent).toBe("Couldn’t switch account");
});

test("Cmd-Ctrl-M over the compact menu opens the full picker in its place", async () => {
  await mount({ routes: [] });
  await open();
  expect(cols()).not.toBeNull();
  await act(async () => {
    dom.window.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", {
        key: "m",
        metaKey: true,
        ctrlKey: true,
        bubbles: true,
      }),
    );
  });
  await settle();
  expect(doc().querySelector(".acpmux-mp")).not.toBeNull();
  expect(cols()).toBeNull();
});

// Leo 2026-10-19: a started chat's menu drew a rail of its one harness, then offered Add harness….
// Once a chat has a message its harness is fixed, as in Claude Code: the compact menu lists its
// models with no rail, and More models opens the full picker, which has no rail either.
test("a started chat's compact menu has no harness rail and no Add harness…", async () => {
  const { added } = await mount({ routes: [] }, { turnCount: 1 });
  await open();
  expect(cols()).toBeNull();
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

// Tabs replace their visible rows while the rail itself stays in place.
test("rail tabs replace their visible content", async () => {
  await mount({ routes: [] }, { fast: true });
  await open();
  const body = () => cols()!.querySelector<HTMLElement>(".acpmux-cols-body")!;
  const rail = body().querySelector(".acpmux-cols-rail");
  const counts: number[] = [];
  const modelLists: string[][] = [];
  for (const name of railTabs().map((tab) => tab.getAttribute("aria-label")!)) {
    await click(railTab(name));
    expect(cols(), `${name} closed the menu`).not.toBeNull();
    expect(railTab(name).getAttribute("aria-selected"), name).toBe("true");
    expect(body().querySelector(".acpmux-cols-rail"), name).toBe(rail);
    modelLists.push(modelNames(cols()!));
    counts.push(body().querySelectorAll('[role="option"], [role="radio"], [role="switch"]').length);
  }
  expect(modelLists.some((models) => models.length > 0)).toBe(true);
  expect(new Set(counts).size).toBeGreaterThan(1);
  expect(new Set(modelLists.map((models) => models.join("|"))).size).toBeGreaterThan(1);
  // A search starts at its first match: the row the list keeps in view.
  await click(railTab("Claude Code"));
  await typeIn("o");
  await settle();
  expect(modelRows(cols()!)[0]!.hasAttribute("data-hl")).toBe(true);
});

// The static "Model · this session" caption is gone from both pickers, in a new chat, a started
// one and on a machine profile (Leo 2026-10-25: "fix the basics first").
test.each([{ turnCount: 0 }, { turnCount: 2 }, { folderProfile: true, currentFolder: true }])(
  "compact and full model pickers omit the redundant session header: %j",
  async (options) => {
    await mount({ routes: [] }, options);
    await open();
    expect(menu()!.textContent).not.toMatch(/Model\s*·\s*this session/i);
    expect(menu()!.querySelector(".ui-menu-group-label")).toBeNull();
    await act(async () => {
      dom.window.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", {
          key: "m",
          metaKey: true,
          ctrlKey: true,
          bubbles: true,
        }),
      );
    });
    await settle();
    const full = doc().querySelector<HTMLElement>(".acpmux-mp");
    expect(full).not.toBeNull();
    expect(full!.textContent).not.toMatch(/Model\s*·\s*this session/i);
  },
);

// The agent CLI's update is maintenance, not a model choice: a quiet footer under the list, out of
// the model rows and the held list height, that a search keeps and whose Update still runs. In the
// columns it ends the frame, below the three columns.
test.each([
  ["a new chat (rail)", {}],
  ["a started chat (no rail)", { turnCount: 1 }],
  ["a machine profile", { folderProfile: true, currentFolder: true }],
] as const)("an agent update sits in a footer below the model list: %s", async (_name, options) => {
  let updated = 0;
  await mount(
    { routes: [] },
    {
      ...options,
      update: {
        harness: "claude",
        agent: "Claude Code",
        version: "2.1.0",
        latest: "2.2.0",
        update: () => {
          updated += 1;
        },
        skip: () => undefined,
      },
    },
  );
  await open();
  const popup = menu()!;
  // The columns' frame holds the keys; the list menu's popup is the frame itself.
  const frame = () => menu()!.querySelector<HTMLElement>(".acpmux-cols-frame") ?? menu()!;
  const footerSelector = ".acpmux-quick-update, .acpmux-cols-update";
  const actionSelector = '[role^="menuitem"], .acpmux-cols-update-action';
  const footer = popup.querySelector<HTMLElement>(footerSelector);
  expect(footer).not.toBeNull();
  expect(footer!.parentElement).toBe(frame());
  expect(frame().lastElementChild).toBe(footer);
  expect(footer!.closest(".acpmux-quick-list, .acpmux-cols-body")).toBeNull();
  expect(footer!.textContent).toContain("2.2.0");
  const actions = [...footer!.querySelectorAll<HTMLElement>(actionSelector)];
  expect(actions.map((item) => item.textContent)).toEqual(["Update"]);
  // No model row carries the update.
  expect(
    [...popup.querySelectorAll<HTMLElement>('[role^="menuitem"], [role="option"]')]
      .filter((item) => !footer!.contains(item))
      .some((item) => item.textContent?.includes("2.2.0")),
  ).toBe(false);
  // A typed search keeps the footer where it is.
  if (field()) {
    await typeIn("opus");
    await settle();
    expect(frame().lastElementChild?.matches(footerSelector)).toBe(true);
  }
  await act(async () => menu()!.querySelector<HTMLElement>(`:is(${footerSelector}) :is(${actionSelector})`)!.click());
  await settle();
  expect(updated).toBe(1);
  expect(menu()).toBeNull();
});

test.each(["claude", "codex"])(
  "Add account submits a local native request and refreshes the picker without switching routes (%s)",
  async (family) => {
    const { postNative, setNativeHost } = await import("../src/agent-session/acpmux/native");
    const calls: { method: string; params: Record<string, unknown> }[] = [];
    const listed = {
      family,
      routes: [{ id: "personal", name: "Personal", kind: "direct-subscription", serves: true }],
      active: { routeId: "personal", scope: "chat" },
    };
    setNativeHost(async (method, params) => {
      if (method !== "account.add") return undefined;
      calls.push({ method, params });
      listed.routes.push({
        id: String(params.id),
        name: String(params.name),
        kind: String(params.kind),
        serves: true,
      });
      return { id: params.id };
    });
    const addDialog = () => doc().querySelector<HTMLElement>(".acpmux-add-account");
    try {
      const state = await mount(listed, {
        addAccount: async (params) => {
          await postNative("account.add", params);
        },
      });
      await open();
      const add = (await openCard()).querySelector<HTMLElement>('.acpmux-cols-add[role="button"]');
      expect(add?.textContent).toContain("Add account…");
      await click(add!);
      // The menu gives way to the dialog.
      expect(cols()).toBeNull();
      const dialog = addDialog()!;
      expect(dialog).not.toBeNull();
      const fill = async (name: string, value: string) => {
        const input = dialog.querySelector<HTMLInputElement>(`input[name="${name}"]`)!;
        await act(async () => {
          Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, value);
          input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
        });
      };
      // No id or folder to type: the new login's id comes from its name, its folder from the id.
      expect(dialog.querySelector('input[name="id"], input[name="accountHome"]')).toBeNull();
      await fill("name", "Work login");
      await act(async () =>
        dialog
          .querySelector("form")!
          .dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true })),
      );
      await settle();
      expect(calls).toEqual([
        {
          method: "account.add",
          params: {
            id: "work-login",
            name: "Work login",
            kind: "direct-subscription",
            family,
            accountHome: "~/.cmux/accounts/work-login",
            ...(family === "codex" ? { shadow: true } : {}),
          },
        },
      ]);
      expect(state.sent.filter((item) => item.method === "route")).toEqual([]);
      expect(addDialog()).toBeNull();
      // The menu comes back with the new account in the card; the chat stays on its own.
      if (!cols()) await open();
      const card = await openCard();
      expect(cardName(card)).toBe("Personal");
      const work = cardRows(card).find((row) => nameOf(row) === "Work login");
      expect(work).toBeDefined();
      expect(work!.getAttribute("aria-disabled")).not.toBe("true");
      expect(state.asked.length).toBeGreaterThanOrEqual(2);
    } finally {
      setNativeHost(undefined);
    }
  },
);

// Lawrence 2026-11-10 ("opus 5.5 medium fast": "we should communicate this better (that medium is selected)") and Leo
// ("codex sol high": "it should highlight the path"): a search that names a level lights that level, checked, in the
// highlighted row's Effort column, as what Enter lands.
test("a search that names a level checks and lights that level in the Effort column", async () => {
  await mount({ routes: [] });
  await open();
  await typeIn("opus high");
  await settle();
  const checked = levels().find((level) => level.getAttribute("aria-checked") === "true");
  expect(checked && nameOf(checked)).toBe("High");
  expect(checked?.hasAttribute("data-named")).toBe(true);
  expect(levels().filter((level) => level.hasAttribute("data-named"))).toHaveLength(1);
});
