// Leo 2026-10-22: "why did you guys even remove the fucking harness model picker in the first place
// down here?", "the harnes picker exists but it's ass and it's not per-account available...?" and
// "need to be able to switch to different harnesses, can expose as fork". Leo 2026-11-06: "So
// forking behavior. Nobody likes seeing this. Everybody wants to see the models." ... "it should
// only need to necessarily fork when you enter a message on that new model". A started chat's model
// menu keeps the New Tab's harness rail with every harness's models: a pick of another harness's
// model is held for the next message (forkHold.ts), which forks through Continue In…; each launch
// configuration is a distinct, readable harness entry rather than a Profile submenu. The real
// composer, catalog and menu, in JSDOM.
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

afterEach(async () => {
  act(() => root?.unmount());
  (await import("../src/agent-session/acpmux/forkHold")).clearHeldFork("s1");
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

/// A Claude chat on the composer's model menu, `turnCount` turns in. `fork`: the chat can fork, to
/// `targets` when named.
async function mount(
  turnCount: number,
  fork?: { targets?: string[] },
  activeHarness = "claude",
  suppliedCatalog?: Snapshot["catalog"],
) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { ChatAccountsContext } = await import("../src/agent-session/acpmux/chatAccounts");
  const catalog = suppliedCatalog ?? (await acpmuxCatalog());
  const switched: string[] = [];
  const models: string[] = [];
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
        onModel={(model) => models.push(model)}
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
  return { switched, models };
}

/// The harness the chat's next message forks to, if a pick is held.
const heldHarness = async () => (await import("../src/agent-session/acpmux/forkHold")).heldFork("s1")?.harness;
const forkMark = () => host.querySelector(".acpmux-model-fork");

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

test("a started chat lists another harness's models, and picking one holds it for the next message", async () => {
  const { switched, models } = await mount(1, {});
  await open();
  const tabs = railTabs().map((tab) => tab.getAttribute("aria-label"));
  expect(tabs).toContain("Claude Code");
  expect(tabs).toContain("Codex");
  await showTab("Codex");
  // Codex's models list as a New Tab's do, and no Fork to row stands in for them.
  const rows = [...menu()!.querySelectorAll<HTMLElement>('.acpmux-quick-list [role="menuitemradio"]')];
  expect(rows.length).toBeGreaterThan(0);
  expect(
    itemsOf(menu()!)
      .map(labelOf)
      .some((label) => label.startsWith("Fork to")),
  ).toBe(false);
  await act(async () => rows[0]!.click());
  await settle();
  // Held, not forked: no switch, no model change here, and the chip draws the fork mark.
  expect(await heldHarness()).toBe("codex");
  expect(switched).toEqual([]);
  expect(models).toEqual([]);
  expect(forkMark()?.getAttribute("aria-label")).toBe("Your next message forks this chat to Codex");
  // The menu opens again on the held tab, the chat's own tab still marked as used here.
  await open();
  expect(
    railTabs()
      .find((tab) => tab.getAttribute("aria-pressed") === "true")
      ?.getAttribute("aria-label"),
  ).toBe("Codex");
  expect(railTabs().find((tab) => tab.getAttribute("aria-label") === "Claude Code")?.dataset.used).toBe("glyph");
});

test("picking the chat's own model again drops the held pick", async () => {
  await mount(1, {});
  await open();
  await showTab("Codex");
  await act(async () => menu()!.querySelector<HTMLElement>('.acpmux-quick-list [role="menuitemradio"]')!.click());
  await settle();
  expect(await heldHarness()).toBe("codex");
  await open();
  await showTab("Claude Code");
  // The running row carries the "used here" mark, and is a pick again while another model is held.
  const running = [...menu()!.querySelectorAll<HTMLElement>('.acpmux-quick-list [role="menuitemradio"]')].find(
    (row) => row.querySelector(".acpmux-used-mark") !== null,
  );
  expect(running).toBeDefined();
  await act(async () => running!.click());
  await settle();
  expect(await heldHarness()).toBeUndefined();
  expect(forkMark()).toBeNull();
});

test("a harness Continue In… can't take is never held", async () => {
  await mount(1, { targets: ["claude-work"] });
  await open();
  await showTab("Codex");
  await act(async () => menu()!.querySelector<HTMLElement>('.acpmux-quick-list [role="menuitemradio"]')!.click());
  await settle();
  expect(await heldHarness()).toBeUndefined();
});

test("launch configurations are named rail entries and never a Profile submenu", async () => {
  const { switched } = await mount(1, {});
  await open();
  expect(itemsOf(menu()!).map(labelOf)).not.toContain("Profile");
  const labels = railTabs().map((tab) => tab.getAttribute("aria-label"));
  expect(labels).toContain("Claude Code");
  expect(labels).toContain("Claude (work)");
  expect(labels).toContain("Codex (work)");
  const launch = railTabs().find((tab) => tab.getAttribute("aria-label") === "Claude (work)");
  expect(launch).toBeDefined();
  await act(async () => launch!.click());
  await settle();
  expect(await heldHarness()).toMatch(/^claude-/);
  expect(switched).toEqual([]);
});

for (const [id, name, family] of [
  ["claude-work", "Claude (work)", "claude-work"],
  ["claude-sr", "Claude (sr)", "claude"],
])
  test(`a started chat can keyboard-hold the launch profile ${id}`, async () => {
    const catalog = [
      { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "opus", name: "Opus" }] },
      { id: id!, name: name!, family: family!, models: [{ id: "opus", name: "Opus" }] },
    ] as Snapshot["catalog"];
    const { switched } = await mount(1, {}, "claude", catalog);
    await open();
    for (let remaining = railTabs().length; remaining > 0; remaining--) {
      if (
        railTabs()
          .find((tab) => tab.getAttribute("aria-pressed") === "true")
          ?.getAttribute("aria-label") === name
      )
        break;
      await act(async () =>
        menu()!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })),
      );
      await settle();
    }
    expect(
      railTabs()
        .find((tab) => tab.getAttribute("aria-pressed") === "true")
        ?.getAttribute("aria-label"),
    ).toBe(name);
    expect(await heldHarness()).toBeUndefined();
    // Enter in the search field takes the launch tab: held for the next message, no fork now.
    const field = menu()!.querySelector<HTMLInputElement>(".acpmux-quick-search input")!;
    await act(async () =>
      field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
    );
    await settle();
    expect(await heldHarness()).toBe(id!);
    expect(switched).toEqual([]);
  });

test("a running turn still lets the chat browse and hold another harness's model", async () => {
  await mount(1, {});
  await open();
  await showTab("Codex");
  await act(async () => menu()!.querySelector<HTMLElement>('.acpmux-quick-list [role="menuitemradio"]')!.click());
  await settle();
  expect(await heldHarness()).toBe("codex");
});

test("a new chat launches a named harness entry from the rail", async () => {
  const { switched } = await mount(0);
  await open();
  expect(itemsOf(menu()!).map(labelOf)).not.toContain("Profile");
  const launch = railTabs().find((tab) => tab.getAttribute("aria-label") === "Claude (work)");
  expect(launch).toBeDefined();
  await act(async () => launch!.click());
  await settle();
  expect(switched).toHaveLength(1);
  expect(switched[0]).toBe("claude-work");
});

test("the chat composer's pick of another harness's model sends nothing until a message", async () => {
  const calls = await mountChat(
    chat(await acpmuxCatalog(), 1, { canHandoff: true, handoff: { ready: true } } as Partial<Snapshot>),
  );
  await open();
  await showTab("Codex");
  await act(async () => menu()!.querySelector<HTMLElement>('.acpmux-quick-list [role="menuitemradio"]')!.click());
  await settle();
  expect(await heldHarness()).toBe("codex");
  expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([]);
});

test("a send with a held pick forks through Continue In…'s chat.handoff.prepare, carrying the message", async () => {
  const { holdFork, heldFork, sendHeldFork } = await import("../src/agent-session/acpmux/forkHold");
  const calls: Record<string, unknown>[] = [];
  const cleared: string[] = [];
  const prepare = async (params: Record<string, unknown>) => {
    calls.push(params);
    return "s2";
  };
  // Nothing held: the send goes on as usual.
  expect(sendHeldFork("s1", "hi", { images: 0, ready: true, prepare })).toBeUndefined();
  holdFork({ sessionId: "s1", harness: "codex", model: "gpt-6.1-sol", effort: "high" });
  // The chat can't fork now (a turn running, a review open), or the message has images: kept.
  expect(sendHeldFork("s1", "hi", { images: 0, ready: false, prepare })).toBe(false);
  expect(sendHeldFork("s1", "hi", { images: 1, ready: true, prepare })).toBe(false);
  expect(calls).toEqual([]);
  await expect(
    sendHeldFork("s1", "fix the build", { images: 0, ready: true, prepare, sent: (id) => cleared.push(id) }),
  ).resolves.toBe("s2");
  expect(calls).toEqual([{ harness: "codex", model: "gpt-6.1-sol", effort: "high", message: "fix the build" }]);
  expect(heldFork("s1")).toBeUndefined();
  expect(cleared).toEqual(["s1"]);
  // A prepare that made no review rejects, so the composer keeps the message; the pick stays.
  holdFork({ sessionId: "s1", harness: "codex" });
  await expect(
    sendHeldFork("s1", "again", { images: 0, ready: true, prepare: async () => undefined }),
  ).rejects.toThrow();
  expect(heldFork("s1")?.harness).toBe("codex");
});

// Catalog joining folds aliases for model data, while the picker keeps each installed launch
// configuration as a named harness entry. With `claude` and `claude-sr` installed, the rail must
// expose both names without a Profile submenu or duplicate generic Claude Code rows.
for (const [id, label] of [
  ["claude-sr", "Claude Code (sr)"],
  ["claude_work", "Claude Code (work)"],
]) {
  test(`a folded family holds the exact ${id} launch entry`, async () => {
    const catalog = [
      { id: "claude", name: "Claude Code", family: "claude", models: [{ id: "opus", name: "Opus" }] },
      { id: id!, name: id!, family: "claude", models: [{ id: "opus", name: "Opus" }] },
    ] as Snapshot["catalog"];
    const { switched } = await mount(1, {}, "claude", catalog);
    await open();
    expect(itemsOf(menu()!).map(labelOf)).not.toContain("Profile");
    await showTab(label!);
    expect(await heldHarness()).toBe(id!);
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
    expect(railTabs().map((tab) => tab.getAttribute("aria-label"))).toEqual(
      expect.arrayContaining([firstLabel, secondLabel]),
    );
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
  const labels = railTabs().map((tab) => tab.getAttribute("aria-label"));
  expect(labels).toEqual(expect.arrayContaining(["Work (work)", "Work (personal)", "Work (work) (travel)"]));
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

// Codex review of #24355 (BLOCK at 443c6a9): the composer's fork read its own readiness, not
// Continue In…'s. The fork now runs on send (sendHeldFork, ready from canContinueIn); a harness no
// Continue In… target is never held. The pane's own chips, from the snapshot alone.
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

test("when no other harness can take the chat, the composer holds no pick of one", async () => {
  // A harness whose probe failed stays in the picker's rail (ComposerPickers) but is no Continue In…
  // target (continueTargets): here every harness but the chat's own.
  const catalog = (await acpmuxCatalog()).map((harness) =>
    harness.id === "claude" ? harness : { ...harness, unavailable: "probe failed", probeFailed: true },
  ) as Snapshot["catalog"];
  const calls = await mountChat(chat(catalog, 1, { canHandoff: true, handoff: { ready: true } } as Partial<Snapshot>));
  await open();
  await showTab("Codex");
  const row = menu()!.querySelector<HTMLElement>('.acpmux-quick-list [role="menuitemradio"]:not([data-disabled])');
  if (row) await act(async () => row.click());
  await settle();
  expect(await heldHarness()).toBeUndefined();
  expect(calls.filter((call) => call.method.startsWith("chat."))).toEqual([]);
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
