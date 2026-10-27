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

async function openProfile() {
  const row = itemsOf(menu()!).find((item) => labelOf(item) === "Profile");
  expect(row, `Profile row in ${itemsOf(menu()!).map(labelOf).join(", ")}`).toBeDefined();
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

test("each harness's Profile row lists only its launch profiles, and another profile forks there", async () => {
  const { forked } = await mount(1, { ready: true });
  await open();
  // Launch profiles are no rail tabs of their own.
  const tabs = railTabs().map((tab) => tab.getAttribute("aria-label"));
  expect(tabs).not.toContain("Claude (work)");
  expect(tabs).not.toContain("Codex (work)");
  const claude = await openProfile();
  expect(profileRows(claude).map(labelOf)).toEqual(["Claude Code", "Claude (work)"]);
  expect(claude.querySelector('.acpmux-quick-profile[aria-checked="true"]')?.textContent).toContain("Claude Code");
  // Real account routes have their own submenu, outside launch profiles.
  expect(itemsOf(claude).map(labelOf)).not.toContain("CLI login");
  await act(async () =>
    profileRows(claude)
      .find((row) => labelOf(row) === "Claude (work)")!
      .click(),
  );
  await settle();
  expect(forked).toEqual(["claude-work"]);
  await open();
  await showTab("Codex");
  const codex = await openProfile();
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

test("a chat with no message yet starts on another launch profile from its Profile row", async () => {
  const { forked, switched } = await mount(0);
  await open();
  expect(railTabs().map((tab) => tab.getAttribute("aria-label"))).not.toContain("Claude (work)");
  const account = await openProfile();
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

// Codex review of #24355: buildPickerCatalog folds every installed profile of a catalog family into
// that harness's one entry, keeping only the profile it runs (`acpmuxHarness`). With `claude` and
// `claude-sr` installed, the live pane's picker saw one Claude Code: a started Claude chat's Account
// row left out `claude-sr`, and nothing forked to it. The real catalog join and the pane's own chips.
test("a family's profiles that the catalog join folds into one harness remain separate launch profiles, and fork", async () => {
  const { BUNDLED_MODEL_CATALOG, buildPickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogData");
  const models = (id: string) =>
    BUNDLED_MODEL_CATALOG.harnesses
      .find((harness) => harness.id === id)!
      .models.map((model) => ({ id: model.id, name: model.name }));
  const catalog = [
    { id: "claude", name: "Claude Code", family: "claude", models: models("claude") },
    { id: "claude-sr", name: "claude-sr", family: "claude", models: models("claude") },
    { id: "codex", name: "Codex", family: "codex", models: models("codex") },
  ] as Snapshot["catalog"];
  // The join keeps one Claude Code entry, on the profile it runs.
  const joined = buildPickerCatalog({
    catalog: BUNDLED_MODEL_CATALOG,
    acpmux: catalog,
    session: { harness: "claude" },
  });
  const claude = joined.harnesses.filter((entry) => entry.acpmuxHarness?.startsWith("claude"));
  expect(claude.map((entry) => entry.acpmuxHarness)).toEqual(["claude"]);

  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ChatComposerChips } = await import("../src/agent-session/acpmux/App");
  const calls: { method: string; params: unknown }[] = [];
  (dom.window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: (_target, method) => async (params: unknown) => void calls.push({ method: String(method), params }) },
  );
  const snapshot = chat(catalog, 1, { canHandoff: true, handoff: { ready: true } } as Partial<Snapshot>);
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
  expect(railTabs().filter((tab) => tab.getAttribute("aria-label") === "Claude Code")).toHaveLength(1);
  const account = await openProfile();
  expect(profileRows(account).map(labelOf)).toEqual(["Claude Code", "claude-sr"]);
  expect(account.querySelector('.acpmux-quick-profile[aria-checked="true"]')?.textContent).toContain("Claude Code");
  await act(async () =>
    profileRows(account)
      .find((row) => labelOf(row) === "claude-sr")!
      .click(),
  );
  await settle();
  expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([
    { method: "chat.handoff.prepare", params: { harness: "claude-sr" } },
  ]);
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

test("when no other harness can take the chat, the composer's Fork to is disabled and sends nothing", async () => {
  // A harness whose probe failed stays in the picker's rail (ComposerPickers) but is no Continue In…
  // target (continueTargets): here every harness but the chat's own.
  const catalog = (await acpmuxCatalog()).map((harness) =>
    harness.id === "claude" ? harness : { ...harness, unavailable: "probe failed", probeFailed: true },
  ) as Snapshot["catalog"];
  const snapshot = chat(catalog, 1, { canHandoff: true, handoff: { ready: true } } as Partial<Snapshot>);
  await forkToCodexDisabled(await mountChat(snapshot));
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
