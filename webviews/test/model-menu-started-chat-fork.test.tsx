// Leo 2026-10-22: "why did you guys even remove the fucking harness model picker in the first place
// down here?", "the harnes picker exists but it's ass and it's not per-account available...?" and
// "need to be able to switch to different harnesses, can expose as fork". A started chat's model
// menu keeps the New Tab's harness rail: another harness's tab forks the chat there, and each
// harness's Account row lists only the accounts (profiles) that run it, folded out of the rail. The
// real composer, catalog and menu, in JSDOM.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
const added: string[] = [];
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: dom.window.Node,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  // The DOM constructors the menus and App's registered elements read at import time.
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
    }
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu")) popup.remove();
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
});

afterAll(() => {
  dom.window.close();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

/// This Mac's acpmux: the bundled catalog's harnesses, and a second account of Claude Code and of
/// Codex (their own profiles, as claude-sr2 is, drawing their brand's mark).
async function acpmuxCatalog(): Promise<Snapshot["catalog"]> {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const models = (id: string) =>
    BUNDLED_MODEL_CATALOG.harnesses
      .find((harness) => harness.id === id)!
      .models.map((model) => ({ id: model.id, name: model.name }));
  return [
    ...BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
      id: harness.id,
      name: harness.name,
      family: harness.families[0],
      models: harness.models.map((model) => ({ id: model.id, name: model.name })),
    })),
    { id: "claude-work", name: "Claude (work)", family: "claude-work", icon: "claude", models: models("claude") },
    { id: "codex-work", name: "Codex (work)", family: "codex-work", icon: "openai", models: models("codex") },
  ] as Snapshot["catalog"];
}

function chat(catalog: Snapshot["catalog"], turnCount: number, extra: Partial<Snapshot> = {}): Snapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary: {
      sessionId: "s1",
      harness: "claude",
      model: "claude-opus-5-5",
      turnCount,
      configOptions: [
        {
          id: "effort",
          name: "Effort",
          category: "thought_level",
          currentValue: "medium",
          options: ["low", "medium", "high"].map((value) => ({ value, name: value })),
        },
      ],
    },
    ...extra,
  } as Snapshot;
}

/// A Claude chat on the composer's model menu, `turnCount` turns in. `fork` is the chat's fork.
async function mount(turnCount: number, fork?: { ready: boolean }) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { ChatAccountsContext } = await import("../src/agent-session/acpmux/chatAccounts");
  const catalog = await acpmuxCatalog();
  const forked: string[] = [];
  const switched: string[] = [];
  const accounts = { list: async () => ({ accounts: [] }), set: async () => undefined };
  function Host() {
    const snapshot = chat(catalog, turnCount);
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" }, snapshot.sessions);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={(harness) => switched.push(harness)}
        {...(fork ? { fork: { to: (harness: string) => forked.push(harness), ready: fork.ready } } : {})}
        showPlan={false}
      />
    );
  }
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <ChatAccountsContext.Provider value={accounts}>
          <Host />
        </ChatAccountsContext.Provider>
      </QueryClientProvider>,
    ),
  );
  return { forked, switched };
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const menu = () => doc().querySelector<HTMLElement>(".acpmux-quick-menu");
const menus = () => [...doc().querySelectorAll<HTMLElement>(".acpmux-quick-menu")];
const railTabs = () => [...(menu()?.querySelectorAll<HTMLElement>(".acpmux-quick-rail-tab") ?? [])];
const labelOf = (item: Element) => item.querySelector(".acpmux-menu-label")?.textContent ?? "";
const itemsOf = (popup: HTMLElement) => [...popup.querySelectorAll<HTMLElement>('[role^="menuitem"]')];

async function open() {
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  await settle();
}

async function showTab(name: string) {
  const tab = railTabs().find((candidate) => candidate.getAttribute("aria-label") === name);
  expect(
    tab,
    `${name} tab in ${railTabs()
      .map((each) => each.getAttribute("aria-label") ?? "")
      .join(", ")}`,
  ).toBeDefined();
  await act(async () => tab!.click());
  await settle();
}

async function openAccount() {
  const row = itemsOf(menu()!).find((item) => labelOf(item) === "Account");
  expect(row, `Account row in ${itemsOf(menu()!).map(labelOf).join(", ")}`).toBeDefined();
  await act(async () => row!.click());
  await settle();
  return menus().at(-1)!;
}

const profileRows = (popup: HTMLElement) => [...popup.querySelectorAll<HTMLElement>(".acpmux-quick-profile")];

test("a started chat's model menu keeps the harness rail, and another harness's tab forks the chat there", async () => {
  const { forked, switched } = await mount(1, { ready: true });
  await open();
  const tabs = railTabs().map((tab) => tab.getAttribute("aria-label"));
  expect(tabs).toContain("Claude Code");
  expect(tabs).toContain("Codex");
  await showTab("Codex");
  // No Codex model is offered as a pick in place: the chat's harness can't change.
  expect(menu()!.querySelectorAll('.acpmux-quick-item[role="menuitemradio"]:not(.acpmux-quick-profile)')).toHaveLength(
    0,
  );
  const fork = itemsOf(menu()!).find((item) => labelOf(item) === "Fork to Codex");
  expect(fork).toBeDefined();
  await act(async () => fork!.click());
  await settle();
  expect(forked).toEqual(["codex"]);
  expect(switched).toEqual([]);
});

test("each harness's Account row lists only its own accounts, and another account forks there", async () => {
  const { forked } = await mount(1, { ready: true });
  await open();
  // The second accounts are no rail tabs of their own.
  const tabs = railTabs().map((tab) => tab.getAttribute("aria-label"));
  expect(tabs).not.toContain("Claude (work)");
  expect(tabs).not.toContain("Codex (work)");
  const claude = await openAccount();
  expect(profileRows(claude).map(labelOf)).toEqual(["Claude Code", "Claude (work)"]);
  expect(claude.querySelector('.acpmux-quick-profile[aria-checked="true"]')?.textContent).toContain("Claude Code");
  // The chat's own routes stay after its accounts.
  expect(itemsOf(claude).map(labelOf)).toContain("CLI login");
  await act(async () =>
    profileRows(claude)
      .find((row) => labelOf(row) === "Claude (work)")!
      .click(),
  );
  await settle();
  expect(forked).toEqual(["claude-work"]);
  await open();
  await showTab("Codex");
  const codex = await openAccount();
  expect(profileRows(codex).map(labelOf)).toEqual(["Codex", "Codex (work)"]);
  // A Fork to tab has no routes: they are the chat's own.
  expect(itemsOf(codex).map(labelOf)).not.toContain("CLI login");
  await act(async () =>
    profileRows(codex)
      .find((row) => labelOf(row) === "Codex (work)")!
      .click(),
  );
  await settle();
  expect(forked).toEqual(["claude-work", "codex-work"]);
});

test("while the chat can't fork (a turn running), Fork to is disabled and does nothing", async () => {
  const { forked } = await mount(1, { ready: false });
  await open();
  await showTab("Codex");
  const fork = itemsOf(menu()!).find((item) => labelOf(item) === "Fork to Codex")!;
  expect(fork.hasAttribute("data-disabled")).toBe(true);
  await act(async () => fork.click());
  await settle();
  expect(forked).toEqual([]);
});

test("a chat with no message yet starts on another account of the harness from its Account row", async () => {
  const { forked, switched } = await mount(0);
  await open();
  expect(railTabs().map((tab) => tab.getAttribute("aria-label"))).not.toContain("Claude (work)");
  const account = await openAccount();
  expect(profileRows(account).map(labelOf)).toEqual(["Claude Code", "Claude (work)"]);
  await act(async () =>
    profileRows(account)
      .find((row) => labelOf(row) === "Claude (work)")!
      .click(),
  );
  await settle();
  expect(switched).toEqual(["claude-work"]);
  expect(forked).toEqual([]);
});

test("the chat composer forks through Continue In…'s chat.handoff.prepare", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ChatComposerChips } = await import("../src/agent-session/acpmux/App");
  const calls: { method: string; params: unknown }[] = [];
  (dom.window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: (_target, method) => async (params: unknown) => void calls.push({ method: String(method), params }) },
  );
  const snapshot = chat(await acpmuxCatalog(), 1, { canHandoff: true, handoff: { ready: true } } as Partial<Snapshot>);
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <ChatComposerChips snapshot={snapshot} />
      </QueryClientProvider>,
    ),
  );
  await settle();
  await open();
  await showTab("Codex");
  await act(async () =>
    itemsOf(menu()!)
      .find((item) => labelOf(item) === "Fork to Codex")!
      .click(),
  );
  await settle();
  expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([
    { method: "chat.handoff.prepare", params: { harness: "codex" } },
  ]);
});
