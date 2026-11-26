// cmux#55750: a started Gemini (Antigravity) chat's model chip opened a list of that harness's
// models alone, so the chat could neither switch nor fork to another agent ("it should be the same
// picker here so i can fork to a different agent as well"). Every chat composer, whatever its
// harness and whether or not it can fork, opens the one shared picker: the harness rail with every
// harness's models. This test fails when any harness gets a menu of its own.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

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

afterEach(async () => {
  // A hold made outside a composer (the send's own tests) goes with the test.
  (await import("../src/agent-session/acpmux/forkHold")).clearHeldFork("s1");
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-cols, .acpmux-quick-menu")) popup.remove();
  delete (dom.window as unknown as { cmuxAcpmuxActions?: unknown }).cmuxAcpmuxActions;
});

afterAll(async () => {
  await settleReact();
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

/// A chat on `activeHarness`, `turnCount` turns in, on the composer's model menu. `fork`: the chat
/// can fork. `sessionId`: the chat's session ("" while its harness has not started one yet).
async function mount(
  turnCount: number,
  fork?: boolean,
  activeHarness = "claude",
  suppliedCatalog?: Snapshot["catalog"],
  sessionId = "s1",
) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { ChatAccountsContext } = await import("../src/agent-session/acpmux/chatAccounts");
  const catalog = suppliedCatalog ?? (await acpmuxCatalog());
  const switched: string[] = [];
  const picked: string[] = [];
  const accounts = { list: async () => ({ accounts: [] }), set: async () => undefined };
  function Host() {
    const snapshot = chat(catalog, turnCount);
    snapshot.summary!.harness = activeHarness;
    snapshot.summary!.sessionId = sessionId;
    // The chat's first message, as a started chat draws it.
    if (turnCount > 0)
      snapshot.rows = [{ id: "u1", version: 1, kind: "user", text: "1+1" } as Snapshot["rows"][number]];
    const own = catalog.find((entry) => entry.id === activeHarness)?.models[0]?.id;
    if (own) snapshot.summary!.model = own;
    const picker = usePickerCatalog(snapshot.catalog, { harness: activeHarness }, snapshot.sessions);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={(model) => picked.push(model)}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={(harness) => switched.push(harness)}
        {...(fork ? { fork } : {})}
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
  return { switched, picked };
}

const doc = () => dom.window.document;
const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
/// The shared picker: the columns menu with its harness rail (QuickModelColumns).
const columns = () => doc().querySelector<HTMLElement>(".acpmux-cols");
/// The list menu a chat's chip opened in place of the shared picker (QuickModelMenu).
const listMenu = () => doc().querySelector<HTMLElement>(".acpmux-quick-menu");
const tabNames = () =>
  [...(columns()?.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]') ?? [])].map(
    (tab) => tab.getAttribute("aria-label") ?? "",
  );

async function click(element: HTMLElement) {
  await act(async () => element.click());
  await settle();
}
const open = () => click(host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!);
async function close() {
  if (columns() || listMenu()) await open();
  for (const popup of doc().querySelectorAll(".acpmux-cols, .acpmux-quick-menu")) popup.remove();
}

/// Antigravity (`agy`), the Gemini chat of cmux#55750: a harness acpmux discovers, which the
/// bundled model catalog does not list.
const ANTIGRAVITY = {
  id: "antigravity",
  name: "Antigravity",
  family: "antigravity",
  models: [
    { id: "gemini-4-hydrogen", name: "Gemini 4 Hydrogen" },
    { id: "gemini-3.8-flash", name: "Gemini 3.8 Flash" },
    { id: "claude-sonnet-4-6-thinking", name: "Claude Sonnet 4.6 (Thinking)" },
  ],
};

async function everyHarness(): Promise<Snapshot["catalog"]> {
  return [...(await acpmuxCatalog()), ANTIGRAVITY] as Snapshot["catalog"];
}

// A started chat that can fork, one that cannot (its daemon serves no forks, or it is the Quick
// Composer), and one whose harness has not started its session yet (a switch still starting).
const STATES = [
  { name: "can fork", fork: true, sessionId: "s1" },
  { name: "cannot fork", fork: false, sessionId: "s1" },
  { name: "no session yet", fork: true, sessionId: "" },
] as const;

test("every harness's started chat opens the one shared picker, with every harness on its rail", async () => {
  const catalog = await everyHarness();
  const separate: string[] = [];
  // UniiChat's chat lists no models of its own; the Chief picks its own model (chief-harness-chip).
  for (const entry of catalog.filter((candidate) => candidate.id !== "unii"))
    for (const state of STATES) {
      await mount(1, state.fork, entry.id, catalog, state.sessionId);
      await open();
      const tabs = tabNames();
      const shared =
        !!columns() && !listMenu() && tabs.includes("Claude Code") && tabs.includes("Codex") && tabs.length > 3;
      if (!shared)
        separate.push(`${entry.id} (${state.name}): ${listMenu() ? "list menu" : `tabs ${tabs.join(", ")}`}`);
      await close();
      act(() => root?.unmount());
      root = undefined;
      host.replaceChildren();
    }
  expect(separate).toEqual([]);
  // Mounts every harness three times: give it room on a loaded runner.
}, 60_000);

test("a started Antigravity chat that cannot fork lists Antigravity on the shared rail and switches to another harness's model", async () => {
  const { switched } = await mount(1, false, "antigravity", await everyHarness());
  await open();
  // Antigravity is a route of the Gemini tab (Lucas 2026-11-25: "just have the gemini symbol").
  expect(tabNames()).toContain("Gemini");
  const codex = [...(columns()?.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]') ?? [])].find(
    (tab) => tab.getAttribute("aria-label") === "Codex",
  )!;
  await click(codex);
  const row = columns()!.querySelector<HTMLElement>('[role="listbox"] [role="option"]')!;
  await click(row);
  expect(switched).toEqual(["codex"]);
});

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

// A host that serves Continue In… but no in-place fork carries the conversation to the picked
// harness through Continue In…'s review, never a blank chat.
test("a started chat whose host cannot fork in place continues in the picked harness", async () => {
  const snapshot = chat(await everyHarness(), 1, { sessionId: "s1", canHandoff: true, canFork: false });
  snapshot.summary!.harness = "antigravity";
  snapshot.summary!.model = "gemini-4-hydrogen";
  snapshot.rows = [{ id: "u1", version: 1, kind: "user", text: "1+1" } as Snapshot["rows"][number]];
  const calls = await mountChat(snapshot);
  await open();
  expect(tabNames()).toContain("Gemini");
  const codex = [...(columns()?.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]') ?? [])].find(
    (tab) => tab.getAttribute("aria-label") === "Codex",
  )!;
  await click(codex);
  await click(columns()!.querySelector<HTMLElement>('[role="listbox"] [role="option"]')!);
  await settle();
  const methods = calls.map((call) => call.method);
  expect(methods).toContain("chat.handoff.prepare");
  expect(methods).not.toContain("chat.new");
  expect(calls.find((call) => call.method === "chat.handoff.prepare")?.params).toEqual({ harness: "codex" });
}, 30_000);

/// The rail tab the menu is on (aria-selected).
const selectedTab = () =>
  [...(columns()?.querySelectorAll<HTMLElement>('.acpmux-cols-rail [role="tab"]') ?? [])]
    .filter((tab) => tab.getAttribute("aria-selected") === "true")
    .map((tab) => tab.getAttribute("aria-label") ?? "");

// The shared picker opens on the chat's own harness's tab, whatever the harness: never the first
// harness on the rail (an Antigravity chat's opened on Claude Code's).
test("every harness's chat opens the shared picker on its own harness's tab", async () => {
  const catalog = await everyHarness();
  const { agentName } = await import("../src/agent-session/acpmux/agents");
  const wrong: string[] = [];
  for (const entry of catalog.filter((candidate) => candidate.id !== "unii"))
    for (const state of STATES) {
      await mount(1, state.fork, entry.id, catalog, state.sessionId);
      await open();
      // A second account of a harness (claude-work) is a route of its harness's tab.
      // Gemini CLI and Antigravity are routes of one Gemini tab (Lucas 2026-11-25).
      const own = ["gemini", "antigravity"].includes(entry.id)
        ? "Gemini"
        : agentName(entry.id.replace(/-work$/, ""), entry.id.endsWith("-work") ? undefined : entry.name);
      const selected = selectedTab();
      if (selected.length !== 1 || selected[0] !== own)
        wrong.push(`${entry.id} (${state.name}): opened on ${selected.join(", ") || "no tab"}, not ${own}`);
      await close();
      act(() => root?.unmount());
      root = undefined;
      host.replaceChildren();
    }
  expect(wrong).toEqual([]);
}, 60_000);

// cmux#55750's dev build: the picker opened on a New Tab (Claude Code, the default harness) stayed
// open while that tab became an Antigravity chat, and still showed Claude Code's tab and models.
// The tab follows the chat's harness while the menu is open.
test("a picker left open while its chat becomes another harness's moves to that harness's tab", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { ChatAccountsContext } = await import("../src/agent-session/acpmux/chatAccounts");
  const catalog = await everyHarness();
  const accounts = { list: async () => ({ accounts: [] }), set: async () => undefined };
  const client = new QueryClient();
  function Host({ harness, model }: { harness: string; model: string }) {
    const snapshot = chat(catalog, 1);
    snapshot.summary!.harness = harness;
    snapshot.summary!.model = model;
    snapshot.rows = [{ id: "u1", version: 1, kind: "user", text: "1+1" } as Snapshot["rows"][number]];
    const picker = usePickerCatalog(snapshot.catalog, { harness }, snapshot.sessions);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={() => undefined}
        fork
        showPlan={false}
      />
    );
  }
  const render = (harness: string, model: string) =>
    act(async () =>
      root!.render(
        <QueryClientProvider client={client}>
          <ChatAccountsContext.Provider value={accounts}>
            <Host harness={harness} model={model} />
          </ChatAccountsContext.Provider>
        </QueryClientProvider>,
      ),
    );
  root = createRoot(host);
  await render("claude", "claude-opus-5-5");
  await open();
  expect(selectedTab()).toEqual(["Claude Code"]);
  await render("antigravity", "gemini-4-hydrogen");
  await settle();
  expect(columns()).not.toBeNull();
  expect(selectedTab()).toEqual(["Gemini"]);
  expect(columns()!.querySelector('[role="listbox"]')?.textContent).toContain("Gemini 4 Hydrogen");
}, 30_000);
