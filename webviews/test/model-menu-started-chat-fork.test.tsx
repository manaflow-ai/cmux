// Leo 2026-10-22: "why did you guys even remove the fucking harness model picker in the first place
// down here?", "the harnes picker exists but it's ass and it's not per-account available...?" and
// "need to be able to switch to different harnesses, can expose as fork". A started chat's model
// menu keeps the New Tab's harness rail: another harness's tab forks the chat there, and each
// launch configuration is a distinct, readable harness entry rather than a Profile submenu. The
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
    { id: "unii", name: "UniiChat", family: "unii", models: [] },
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
async function mount(
  turnCount: number,
  fork?: { ready: boolean },
  activeHarness = "claude",
  suppliedCatalog?: Snapshot["catalog"],
) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { ChatAccountsContext } = await import("../src/agent-session/acpmux/chatAccounts");
  const catalog = suppliedCatalog ?? (await acpmuxCatalog());
  const forked: string[] = [];
  const switched: string[] = [];
  const accounts = { list: async () => ({ accounts: [] }), set: async () => undefined };
  function Host() {
    const snapshot = chat(catalog, turnCount);
    snapshot.summary!.harness = activeHarness;
    if (activeHarness === "unii") snapshot.summary!.model = "unii/default";
    const picker = usePickerCatalog(snapshot.catalog, { harness: activeHarness }, snapshot.sessions);
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
const railTabs = () => [...(menu()?.querySelectorAll<HTMLElement>(".acpmux-quick-rail-tab") ?? [])];
const labelOf = (item: Element) => item.querySelector(".acpmux-menu-label")?.textContent ?? "";
const itemsOf = (popup: HTMLElement) => [...popup.querySelectorAll<HTMLElement>('[role^="menuitem"]')];

async function open() {
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  await settle();
}

// One tab per model family (Leo 2026-10-31: "FUCKING HELL WHY DO YOU GUYS STILLLLLLLLLLLLLLLLLLLLLL
// SHOW THESE AS SEPARATE HARNESSES" / "THE FUCKING APP SERVER THE FUCKING SR"): a launch
// configuration or transport of a family is a route in the menu's Account row, never a tab.
const tabNames = () => railTabs().map((tab) => tab.getAttribute("aria-label") ?? "");

/// The Account row's routes (opening it first): the family's launch entries and transports.
async function routeItems(): Promise<HTMLElement[]> {
  const listed = () => [...doc().querySelectorAll<HTMLElement>(".acpmux-quick-route")];
  if (listed().length) return listed();
  const account = menu()?.querySelector<HTMLElement>(".acpmux-quick-account");
  if (!account) return [];
  await act(async () => account.click());
  await settle();
  return listed();
}
const routeNames = async () => (await routeItems()).map(labelOf);

/// Every harness entry the menu offers: the family tabs and the shown family's routes.
async function entryNames(): Promise<string[]> {
  const names = tabNames();
  const families = railTabs().filter((tab) => !tab.classList.contains("acpmux-quick-rail-add"));
  for (const tab of families) {
    await act(async () => tab.click());
    await settle();
    if (!menu()) await open();
    for (const name of await routeNames()) if (!names.includes(name)) names.push(name);
  }
  return names;
}

/// Shows an entry's models: its family tab, or the route of that name in its family's Account row.
async function showTab(name: string) {
  const tab = railTabs().find((candidate) => candidate.getAttribute("aria-label") === name);
  if (tab) {
    await act(async () => tab.click());
    await settle();
    return;
  }
  for (const family of railTabs().filter((each) => !each.classList.contains("acpmux-quick-rail-add"))) {
    if (!menu()) await open();
    await act(async () => family.click());
    await settle();
    const route = (await routeItems()).find((item) => labelOf(item) === name);
    if (route) {
      await act(async () => route.click());
      await settle();
      return;
    }
  }
  expect(undefined, `${name} in tabs ${tabNames().join(", ")}`).toBeDefined();
}

test("the Unii Chief harness is absent from an ordinary chat picker", async () => {
  await mount(0);
  await open();
  const labels = railTabs().map((tab) => tab.getAttribute("aria-label"));
  expect(labels).not.toContain("UniiChat");
  expect(labels).not.toContain("U");
  expect(menu()!.textContent).not.toContain("Unii");
});

test("the active Unii Chief chat keeps its own harness entry", async () => {
  await mount(0, undefined, "unii");
  await open();
  expect(railTabs().map((tab) => tab.getAttribute("aria-label"))).toContain("UniiChat");
});

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

test("launch configurations are named rail entries and never a Profile submenu", async () => {
  const { forked } = await mount(1, { ready: true });
  await open();
  expect(itemsOf(menu()!).map(labelOf)).not.toContain("Profile");
  expect(tabNames()).not.toContain("Claude (work)");
  const labels = await entryNames();
  expect(labels).toContain("Claude Code");
  expect(labels).toContain("Claude (work)");
  expect(labels).toContain("Codex (work)");
  await showTab("Claude (work)");
  await act(async () =>
    itemsOf(menu()!)
      .find((item) => labelOf(item) === "Fork to Claude (work)")!
      .click(),
  );
  await settle();
  expect(forked).toEqual(["claude-work"]);
});

for (const [id, name, family] of [
  ["claude-work", "Claude (work)", "claude-work"],
  ["claude-sr", "Claude (sr)", "claude"],
])
  test(`a started chat forks to the launch profile ${id} from its Account route`, async () => {
    // A Codex chat: a Claude profile is no target of a Claude chat's own family (continueTargets).
    // Claude Code is in the catalog, so the profile is a route of the Claude tab, never a tab.
    const catalog = [
      { id: "codex", name: "Codex", family: "codex", models: [{ id: "gpt-6", name: "GPT-6" }] },
      { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "opus", name: "Opus" }] },
      { id: id!, name: name!, family: family!, models: [{ id: "opus", name: "Opus" }] },
    ] as Snapshot["catalog"];
    const { forked, switched } = await mount(1, { ready: true }, "codex", catalog);
    await open();
    expect(tabNames()).not.toContain(name);
    await showTab(name!);
    // Close the Account submenu so the menu's own rows are what the queries below read.
    for (const route of doc().querySelectorAll(".acpmux-quick-route")) route.closest(".ui-popup")?.remove();
    // A launch profile folded into its family (claude-sr) forks from its route at once, as its tab
    // did; one with its own catalog entry (claude-work) shows its Fork to row.
    if (forked.length) {
      expect(forked).toEqual([id!]);
      expect(switched).toEqual([]);
      return;
    }
    expect(menu()!.querySelectorAll('.acpmux-quick-item[role="menuitemradio"]')).toHaveLength(0);
    expect(itemsOf(menu()!).map(labelOf)).toContain(`Fork to ${name}`);
    await act(async () =>
      itemsOf(menu()!)
        .find((item) => labelOf(item) === `Fork to ${name}`)!
        .click(),
    );
    await settle();
    expect(forked).toEqual([id!]);
    expect(switched).toEqual([]);
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

test("a new chat starts a named harness entry from one of its own models", async () => {
  const { switched } = await mount(0);
  await open();
  expect(itemsOf(menu()!).map(labelOf)).not.toContain("Profile");
  await showTab("Claude (work)");
  expect(switched).toEqual([]);
  const pick = menu()!.querySelector<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]');
  expect(pick).not.toBeNull();
  await act(async () => pick!.click());
  await settle();
  expect(switched).toEqual(["claude-work"]);
});

test("a new chat still launches a named harness entry that lists no models from its tab", async () => {
  const catalog = [
    { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "opus", name: "Opus" }] },
    { id: "claude-work", name: "Claude (work)", family: "claude-work", icon: "claude", models: [] },
  ] as Snapshot["catalog"];
  const { switched } = await mount(0, undefined, "claude", catalog);
  await open();
  await showTab("Claude (work)");
  expect(switched).toEqual(["claude-work"]);
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

// Catalog joining folds aliases for model data, while the picker keeps each installed launch
// configuration as a named harness entry. With `claude` and `claude-sr` installed, the rail must
// expose both names without a Profile submenu or duplicate generic Claude Code rows.
for (const [id, label] of [
  ["claude-sr", "Claude Code (sr)"],
  ["claude_work", "Claude Code (work)"],
]) {
  test(`a folded family forks to the exact ${id} launch entry`, async () => {
    const catalog = [
      { id: "codex", name: "Codex", family: "codex", models: [{ id: "gpt-6", name: "GPT-6" }] },
      { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "opus", name: "Opus" }] },
      { id: id!, name: id!, family: "claude", models: [{ id: "opus", name: "Opus" }] },
    ] as Snapshot["catalog"];
    const { forked, switched } = await mount(1, { ready: true }, "codex", catalog);
    await open();
    expect(itemsOf(menu()!).map(labelOf)).not.toContain("Profile");
    await showTab(label!);
    expect(forked).toEqual([id!]);
    expect(switched).toEqual([]);
  });
}

for (const [first, second, firstLabel, secondLabel] of [
  ["claude-work", "claude-sr", "Work (work)", "Work (sr)"],
  ["work", "personal", "Work (work)", "Work (personal)"],
  ["claude-work", "work", "Work (work)", "Work"],
])
  test(`duplicate configured names distinguish ${first} and ${second}`, async () => {
    const catalog = [
      { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "opus", name: "Opus" }] },
      { id: first!, name: "Work", family: "claude", models: [] },
      { id: second!, name: "Work", family: "claude", models: [] },
    ] as Snapshot["catalog"];
    const { switched } = await mount(0, undefined, "claude", catalog);
    await open();
    expect(await routeNames()).toEqual(expect.arrayContaining([firstLabel, secondLabel]));
    await showTab(secondLabel!);
    expect(switched).toEqual([second]);
  });

test("a configured suffix collision keeps every launch profile readable", async () => {
  const catalog = [
    { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "opus", name: "Opus" }] },
    { id: "work", name: "Work", family: "claude", models: [] },
    { id: "personal", name: "Work", family: "claude", models: [] },
    { id: "travel", name: "Work (work)", family: "claude", models: [] },
  ] as Snapshot["catalog"];
  await mount(0, undefined, "claude", catalog);
  await open();
  expect(await routeNames()).toEqual(
    expect.arrayContaining(["Work (work)", "Work (personal)", "Work (work) (travel)"]),
  );
});

test("familyProfiles lists every global profile of the running profile's family", async () => {
  const { familyProfiles } = await import("../src/agent-session/acpmux/pickerProfiles");
  const catalog = [
    { id: "claude", name: "Claude Code", family: "claude", models: [] },
    { id: "claude-sr", name: "claude-sr", family: "claude", models: [] },
    { id: "codex", name: "Codex", family: "codex", models: [] },
    {
      id: "claude-dir",
      name: "Folder Claude",
      family: "claude",
      models: [],
      folder: { folder: "/f", state: "enabled" },
    },
  ] as Snapshot["catalog"];
  expect(familyProfiles(catalog, "claude-sr")).toEqual([
    { id: "claude", name: "Claude Code" },
    { id: "claude-sr", name: "claude-sr" },
  ]);
  expect(familyProfiles(catalog, "gemini")).toEqual([]);
});

// Codex review of #24355 (BLOCK at 443c6a9): the composer's Fork to read its own readiness, not
// Continue In…'s, so it stayed on while the chat's handoff review was open or no harness could take
// the chat, and sent chat.handoff.prepare anyway. The pane's own chips, from the snapshot alone.
async function mountChat(snapshot: Snapshot) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ChatComposerChips } = await import("../src/agent-session/acpmux/App");
  const calls: { method: string; params: unknown }[] = [];
  (dom.window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: (_target, method) => async (params: unknown) => void calls.push({ method: String(method), params }) },
  );
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <ChatComposerChips snapshot={snapshot} />
      </QueryClientProvider>,
    ),
  );
  await settle();
  return calls;
}

async function forkToCodexDisabled(calls: { method: string }[]) {
  await open();
  await showTab("Codex");
  const fork = itemsOf(menu()!).find((item) => labelOf(item) === "Fork to Codex");
  expect(fork, `Fork to Codex in ${itemsOf(menu()!).map(labelOf).join(", ")}`).toBeDefined();
  expect(fork!.hasAttribute("data-disabled")).toBe(true);
  await act(async () => fork!.click());
  await settle();
  expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([]);
}

test("while the chat's handoff review is open, the composer's Fork to is disabled and sends nothing", async () => {
  const snapshot = chat(await acpmuxCatalog(), 1, {
    sessionId: "s1",
    canHandoff: true,
    handoff: { ready: true, record: { target: { sessionId: "s1" }, state: "draft" } },
  } as unknown as Partial<Snapshot>);
  await forkToCodexDisabled(await mountChat(snapshot));
});

test("when no other harness can take the chat, the composer offers no Fork to and sends nothing", async () => {
  // A failed probe is no Continue In… target, so it is no Fork to destination either.
  // Here every harness but the chat's own failed its probe.
  const catalog = (await acpmuxCatalog()).map((harness) =>
    harness.id === "claude" ? harness : { ...harness, unavailable: "probe failed", probeFailed: true },
  ) as Snapshot["catalog"];
  const snapshot = chat(catalog, 1, { canHandoff: true, handoff: { ready: true } } as Partial<Snapshot>);
  const calls = await mountChat(snapshot);
  await open();
  expect(railTabs().map((tab) => tab.getAttribute("aria-label"))).toEqual(["Claude Code"]);
  expect(
    itemsOf(menu()!)
      .map(labelOf)
      .some((label) => label.startsWith("Fork to ")),
  ).toBe(false);
  expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([]);
});

test("another profile of the chat's own family is no Fork to target (the daemon refuses same_harness)", async () => {
  const { continueTargets } = await import("../src/agent-session/acpmux/cmuxCommands");
  const catalog = [
    { id: "claude", name: "Claude Code", family: "claude" },
    { id: "cmux", name: "cmux router", family: "claude" },
    { id: "codex", name: "Codex", family: "codex" },
  ];
  expect(continueTargets(catalog, "claude").map((target) => target.id)).toEqual(["codex"]);
  expect(continueTargets(catalog, "cmux", "claude").map((target) => target.id)).toEqual(["codex"]);
  expect(continueTargets(catalog, "codex").map((target) => target.id)).toEqual(["claude", "cmux"]);
});

for (const [source, catalogFamily] of [
  ["claude", "claude"],
  ["work", "codex"],
])
  test(`the composer excludes same-family forks while another family can take the chat (${source})`, async () => {
    const catalog = [
      { id: source!, name: "Claude Code", family: catalogFamily!, models: [{ id: "opus", name: "Opus" }] },
      { id: "claude-sr", name: "Claude (sr)", family: "claude", models: [{ id: "opus", name: "Opus" }] },
      { id: "codex", name: "Codex", family: "codex", models: [{ id: "gpt-6", name: "GPT-6" }] },
    ] as Snapshot["catalog"];
    const snapshot = chat(catalog, 1, { canHandoff: true, handoff: { ready: true } });
    snapshot.summary = { ...snapshot.summary!, harness: source!, family: "claude" };
    const calls = await mountChat(snapshot);
    await open();
    expect(railTabs().map((tab) => tab.getAttribute("aria-label"))).not.toContain("Claude (sr)");
    expect(menu()!.querySelectorAll('.acpmux-quick-item[role="menuitemradio"]').length).toBeGreaterThan(0);
    expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([]);
    await showTab("Codex");
    // A folded profile with no models launches from the rail tab; otherwise its row confirms it.
    const popup = menu();
    if (popup) {
      const fork = itemsOf(popup).find((item) => labelOf(item) === "Fork to Codex")!;
      expect(fork.hasAttribute("data-disabled")).toBe(false);
      await act(async () => fork.click());
      await settle();
    }
    expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([
      { method: "chat.handoff.prepare", params: { harness: "codex" } },
    ]);
  });

test("Continue In uses the live session's family after its profile is reloaded", async () => {
  const { canContinueIn } = await import("../src/agent-session/acpmux/handoff/continueIn");
  const catalog = [
    { id: "work", name: "Work", family: "codex" },
    { id: "codex", name: "Codex", family: "codex" },
  ] as Snapshot["catalog"];
  const snapshot = chat(catalog, 1, { canHandoff: true, handoff: { ready: true } });
  snapshot.summary = { ...snapshot.summary!, harness: "work", family: "claude" };
  expect(canContinueIn(snapshot)).toBe(true);
  snapshot.catalog = [catalog[0]!, { id: "claude", name: "Claude", family: "claude" }] as Snapshot["catalog"];
  expect(canContinueIn(snapshot)).toBe(false);
});

test("canContinueIn is Continue In…'s whole check", async () => {
  const { canContinueIn } = await import("../src/agent-session/acpmux/handoff/continueIn");
  const catalog = await acpmuxCatalog();
  const ready = { canHandoff: true, handoff: { ready: true } } as Partial<Snapshot>;
  expect(canContinueIn(chat(catalog, 1, ready))).toBe(true);
  expect(canContinueIn(chat(catalog, 1, { ...ready, isWorking: true }))).toBe(false);
  expect(canContinueIn(chat(catalog, 1, { ...ready, queue: [{ id: "q", prompt: "p" }] } as Partial<Snapshot>))).toBe(
    false,
  );
  expect(canContinueIn(chat(catalog, 1, { ...ready, handoff: { ready: true, busy: "preparing" } }))).toBe(false);
  expect(
    canContinueIn(
      chat(catalog, 1, {
        ...ready,
        sessionId: "s1",
        handoff: { ready: true, record: { target: { sessionId: "s1" }, state: "starting" } },
      } as unknown as Partial<Snapshot>),
    ),
  ).toBe(false);
  expect(
    canContinueIn(
      chat(
        catalog.filter((harness) => harness.id === "claude"),
        1,
        ready,
      ),
    ),
  ).toBe(false);
});

// Regression (cmux NEXT nightly, 2026-10-29): #26969 folded every harness drawing the Claude or
// Codex mark into one tab, so a custom harness such as claude-sr2 (its own profile, `icon =
// "claude"`) lost its rail tab and its model list. Each harness keeps its own tab and models,
// whichever harness the chat runs.
const sr2Catalog = [
  { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "claude-opus-5-5", name: "Claude Opus 5.5" }] },
  {
    id: "claude-sr2",
    name: "Claude Code (sr2 internal)",
    family: "claude-sr2",
    icon: "claude",
    models: [
      { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
      { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5" },
    ],
  },
  { id: "codex", name: "Codex", family: "codex", icon: "openai", models: [{ id: "gpt-6", name: "GPT-6" }] },
  { id: "codex-work", name: "Codex (work)", family: "codex-work", icon: "openai", models: [] },
] as Snapshot["catalog"];

for (const running of ["claude-sr2", "claude"])
  test(`a custom Claude-marked harness is a route of the Claude tab and lists its models (running ${running})`, async () => {
    const { switched } = await mount(0, undefined, running, sr2Catalog);
    await open();
    // One Claude tab and one Codex tab: claude-sr2 and Codex (work) are their routes.
    expect(tabNames().filter((name) => name.includes("sr2") || name === "Codex (work)")).toEqual([]);
    const labels = await entryNames();
    expect(labels).toContain("Claude Code");
    const sr2 = labels.find((label) => label.includes("sr2"));
    expect(sr2, labels.join(", ")).toBeDefined();
    expect(labels).toContain("Codex");
    expect(labels).toContain("Codex (work)");
    expect(menu()!.querySelector(".acpmux-quick-variant")).toBeNull();
    await showTab(sr2!);
    expect(switched).toEqual([]);
    const models = [...menu()!.querySelectorAll<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]')];
    const sonnet = models.find((item) => (item.textContent ?? "").includes("Sonnet 5.5"));
    expect(sonnet, models.map((item) => item.textContent ?? "").join(" | ")).toBeDefined();
    if (running === "claude-sr2") return;
    await act(async () => sonnet!.click());
    await settle();
    expect(switched).toEqual(["claude-sr2"]);
  });

// Two launch entries of one uncatalogued family: the second is a profile of the first, and still
// lists its own catalog models (never the first's) and starts itself.
test("a second launch entry of a family lists its own models and starts itself", async () => {
  const catalog = [
    { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "opus", name: "Opus" }] },
    {
      id: "claude-sr2",
      name: "Claude Code (sr2)",
      family: "claude-sr2",
      icon: "claude",
      models: [{ id: "claude-opus-5-5", name: "Claude Opus 5.5" }],
    },
    {
      id: "claude-sr2-alt",
      name: "Claude Code (sr2 alt)",
      family: "claude-sr2",
      icon: "claude",
      models: [{ id: "claude-haiku-5-5", name: "Claude Haiku 5.5" }],
    },
  ] as Snapshot["catalog"];
  const { switched } = await mount(0, undefined, "claude", catalog);
  await open();
  const labels = await routeNames();
  const alt = labels.filter((label) => label.includes("alt"));
  expect(alt, labels.join(", ")).toHaveLength(1);
  await showTab(alt[0]!);
  expect(switched).toEqual([]);
  const models = [...menu()!.querySelectorAll<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]')];
  const texts = models.map((item) => item.textContent ?? "");
  expect(
    texts.some((text) => text.includes("Haiku 5.5")),
    texts.join(" | "),
  ).toBe(true);
  expect(
    texts.some((text) => text.includes("Opus 5.5")),
    texts.join(" | "),
  ).toBe(false);
  await act(async () => models.find((item) => (item.textContent ?? "").includes("Haiku 5.5"))!.click());
  await settle();
  expect(switched).toEqual(["claude-sr2-alt"]);
});

// A launch entry whose probe failed (its catalog entry unavailable) keeps its one-click launch tab,
// even when its catalog still lists a model that looks pickable: it is stale (review of #27692).
test("a new chat still launches a named harness entry whose probe failed from its tab", async () => {
  const catalog = [
    { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "opus", name: "Opus" }] },
    {
      id: "claude-work",
      name: "Claude (work)",
      family: "claude-work",
      icon: "claude",
      // A failed probe keeps the harness in the rail (ComposerPickers keeps `probeFailed` entries).
      unavailable: "probe failed",
      probeFailed: true,
      models: [{ id: "opus-stale", name: "Opus Stale" }],
    },
  ] as Snapshot["catalog"];
  const { switched } = await mount(0, undefined, "claude", catalog);
  await open();
  await showTab("Claude (work)");
  expect(switched).toEqual(["claude-work"]);
});

// Review of #28050: a launch tab reached with the arrow keys (no launch) shows none of its rows, and
// a failed probe's stale models are not in the compact menu's search.
test("a failed probe's launch tab shows no rows when reached with the arrows, and search finds none of them", async () => {
  const catalog = [
    { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "opus", name: "Opus" }] },
    {
      id: "claude-work",
      name: "Claude (work)",
      family: "claude-work",
      icon: "claude",
      unavailable: "probe failed",
      probeFailed: true,
      models: [{ id: "opus-stale", name: "Opus Stale" }],
    },
  ] as Snapshot["catalog"];
  const { switched } = await mount(0, undefined, "claude", catalog);
  await open();
  const rows = () =>
    [...(menu()?.querySelectorAll<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]') ?? [])].map(
      (item) => item.textContent ?? "",
    );
  for (let step = 0; step < 4 && !rows().some((text) => text.includes("Stale")); step++) {
    await act(async () => {
      menu()!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
    });
    await settle();
  }
  expect(
    rows().some((text) => text.includes("Stale")),
    rows().join(" | "),
  ).toBe(false);
  expect(switched).toEqual([]);
});
