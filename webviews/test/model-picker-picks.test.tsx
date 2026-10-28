// Leo 2026-10-11: clicking Opus 5.5 selected Sonnet 5, and GPT-6 Astra gave 6 Sol. At the
// composer's boundary: the real model catalog, the real picker, and a host that applies what the
// pane sends as acpmux does. A click on each row of each provider sends that row's model id, and
// the chip then names that model.
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
/// What the pages asked the app to remember (`newTab.remember`), oldest first.
let remembered: Record<string, unknown>[] = [];

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

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings({ harnessSwitch: false });
  host.replaceChildren();
  dom.window.localStorage.clear();
  remembered = [];
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Sent = { method: "model" | "harness" | "effort"; value: string };

async function mount(start: {
  harness: string;
  extra?: {
    id: string;
    name: string;
    family?: string;
    models?: { id: string; name: string }[];
    unavailable?: string;
    probeFailed?: boolean;
    folder?: { folder: string; state: "enabled" | "needs-enable" | "needs-trust" | "error" };
  }[];
  /// Completed turns of the shown chat: none (the default) is a chat with no message yet.
  turnCount?: number;
  /// acpmux's session list (the sidebar's Chats).
  sessions?: import("../src/agent-session/acpmux/model").AcpmuxSnapshot["sessions"];
  /// Add harness…: each click is counted.
  onAddAgent?: () => void;
  onHarnessEnable?: (folder: string, id: string) => void;
}) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  // acpmux's harness list: what `_acpmux/models` reports for each catalog harness.
  const acpmux: Snapshot["catalog"] = BUNDLED_MODEL_CATALOG.harnesses
    .map((harness) => ({
      id: harness.id,
      name: harness.name,
      family: harness.families[0],
      models: harness.models.map((model) => ({ id: model.id, name: model.name })),
    }))
    .concat(
      (start.extra ?? []).map((entry) => ({ family: entry.id, ...entry, models: entry.models ?? [] })),
    ) as Snapshot["catalog"];
  const sent: Sent[] = [];
  let session = 0;
  function Host() {
    const [state, setState] = useState({
      sessionId: `s${session}`,
      harness: start.harness,
      model: "default",
      effort: "medium",
    });
    const snapshot: Snapshot = {
      type: "snapshot",
      protocolVersion: 1,
      rows: [],
      sessions: start.sessions ?? [],
      connection: "test",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      catalog: acpmux,
      summary: {
        sessionId: state.sessionId,
        harness: state.harness,
        model: state.model,
        turnCount: start.turnCount ?? 0,
        configOptions: [
          {
            id: "effort",
            name: "Effort",
            category: "thought_level",
            currentValue: state.effort,
            options: ["low", "medium", "high"].map((value) => ({ value, name: value })),
          },
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
        onEffort={(_id, value) => {
          sent.push({ method: "effort", value });
          setState((current) => ({ ...current, effort: value }));
        }}
        onHarness={(harness, model) => {
          sent.push({ method: "harness", value: model ? `${harness}/${model}` : harness });
          session += 1;
          setState({ sessionId: `s${session}`, harness, model: model ?? "default", effort: "medium" });
        }}
        showPlan={false}
        {...(start.onAddAgent ? { onAddAgent: start.onAddAgent } : {})}
        {...(start.onHarnessEnable ? { onHarnessEnable: start.onHarnessEnable } : {})}
      />
    );
  }
  const client = new QueryClient();
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={client}>
        <Host />
      </QueryClientProvider>,
    );
  });
  return { sent, catalog: BUNDLED_MODEL_CATALOG };
}

/// The full picker, as More models' shortcut opens it (Cmd-Ctrl-M): the composer's model button opens
/// the compact menu first (Leo 2026-10-20: one model button), and the full picker is reached from it.
const openFullPicker = () =>
  dom.window.dispatchEvent(
    new dom.window.KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true, bubbles: true }),
  );

// The model the chip names, in full: its title (the visible name drops the vendor its mark draws).
const chip = () => host.querySelector('[data-menu="Model"]')?.getAttribute("title") ?? "";

async function openOn(harnessName: string) {
  if (!host.querySelector(".acpmux-mp"))
    await act(async () => {
      openFullPicker();
    });
  const tabs = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")];
  const tab = tabs.find((button) => button.title.split(" · ")[0] === harnessName);
  expect(tab, `rail tab ${harnessName} in ${tabs.map((button) => button.title).join(", ")}`).toBeDefined();
  await act(async () => tab!.click());
  // Older versions fold under one row: open it so every model is a row.
  const more = host.querySelector<HTMLButtonElement>(".acpmux-mp-older");
  if (more && more.getAttribute("aria-expanded") !== "true") await act(async () => more.click());
}

const rows = () =>
  [...host.querySelectorAll<HTMLElement>('.acpmux-mp-models [role="option"][data-key^="model:"]')].filter(
    (row) => !row.hasAttribute("disabled"),
  );

for (const provider of [
  { harness: "claude", name: "Claude Code" },
  { harness: "codex", name: "Codex" },
]) {
  test(`every ${provider.name} row lands its own model, and the chip names it`, async () => {
    const { sent, catalog } = await mount({ harness: provider.harness });
    const listed = catalog.harnesses.find((entry) => entry.id === provider.harness)!.models;
    await openOn(provider.name);
    const ids = rows().map((row) => row.dataset.key!.slice("model:".length));
    expect(ids.length).toBeGreaterThan(3);
    for (const id of ids) {
      await openOn(provider.name);
      const row = rows().find((candidate) => candidate.dataset.key === `model:${id}`)!;
      const label = row.querySelector(".acpmux-menu-label")!.textContent!;
      sent.length = 0;
      await act(async () => row.click());
      expect({ id, sent }).toEqual({ id, sent: [{ method: "model", value: id }] });
      const model = listed.find((entry) => entry.id === id);
      expect({ id, chip: chip() }).toEqual({ id, chip: model?.name ?? label });
    }
  });
}

test("before its first message, a row of another provider starts that provider on that row's model", async () => {
  const { sent } = await mount({ harness: "claude" });
  await openOn("Codex");
  const astra = rows().find((row) => row.dataset.key === "model:gpt-6-astra")!;
  await act(async () => astra.click());
  // One switch carries the model: the new chat starts on it, with no second model request.
  expect(sent).toEqual([{ method: "harness", value: "codex/gpt-6-astra" }]);
  expect(chip()).toBe("GPT-6 Astra");
});

// Leo 2026-10-13 (cosmic-gray): in a running claude-sr chat, picking a ChatGPT model started a
// Codex session in the tab, and picking Claude again started a bare `claude` one that was signed
// out; the chat itself left the sidebar. Once a chat has a message its harness is fixed: the picker
// lists that harness's models only, and crossing to another is Continue In…, never a pick.
// Leo 2026-10-19: the menu still drew a rail of that one harness and then offered Add harness…; a
// started chat's menu is search, its harness's models and More models, as in Claude Code.
test("a started chat's picker lists only its own harness, and no pick or search leaves it", async () => {
  let added = 0;
  const { sent } = await mount({
    harness: "claude-sr",
    turnCount: 1,
    extra: [{ id: "claude-sr", name: "Claude Code (subrouter)", family: "claude" }],
    onAddAgent: () => (added += 1),
  });
  await act(async () => {
    openFullPicker();
  });
  const menu = host.querySelector<HTMLElement>(".acpmux-mp")!;
  expect(menu.querySelector(".acpmux-mp-rail-scroll")).toBeNull();
  expect(menu.querySelector(".acpmux-mp-harness")).toBeNull();
  expect(menu.querySelector(".acpmux-mp-add-harness")).toBeNull();
  expect(rows().length).toBeGreaterThan(0);
  expect(menu.querySelector(".acpmux-mp-older")).not.toBeNull();
  const search = host.querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]')!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(search, "gpt");
    search.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  expect(rows().map((row) => row.dataset.key)).toEqual([]);
  await act(async () => {
    search.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(sent).toEqual([]);
  expect(added).toBe(0);
});

test("before its first message, the picker's rail lists every installed harness and Add harness…", async () => {
  let added = 0;
  await mount({ harness: "codex", onAddAgent: () => (added += 1) });
  await act(async () => {
    openFullPicker();
  });
  const tabs = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].map(
    (button) => button.title.split(" · ")[0],
  );
  expect(tabs).toContain("Claude Code");
  expect(tabs).toContain("Codex");
  expect(host.querySelector(".acpmux-mp-rail-scroll [aria-label='Starred']")).not.toBeNull();
  const add = host.querySelector<HTMLButtonElement>(".acpmux-mp-add-harness")!;
  expect(add).not.toBeNull();
  await act(async () => add.click());
  expect(added).toBe(1);
});

test("before its first message, a machine profile is absent from the harness rail", async () => {
  await mount({
    harness: "codex",
    extra: [
      {
        id: "machine-profile",
        name: "Build machine",
        folder: { folder: "/Users/me/app", state: "enabled" },
      },
    ],
  });
  await act(async () => {
    openFullPicker();
  });
  const tabs = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].map(
    (button) => button.title.split(" · ")[0],
  );
  expect(tabs).toContain("Claude Code");
  expect(tabs).toContain("Codex");
  expect(tabs).not.toContain("Build machine");
});

test("a non-current folder profile keeps its Enable action outside the harness rail", async () => {
  const enabled: string[] = [];
  await mount({
    harness: "codex",
    extra: [
      {
        id: "machine-profile",
        name: "Build machine",
        folder: { folder: "/Users/me/app", state: "needs-enable" },
      },
    ],
    onHarnessEnable: (folder, id) => enabled.push(`${folder}:${id}`),
  });
  await act(async () => {
    openFullPicker();
  });
  const profile = host.querySelector<HTMLButtonElement>(".acpmux-mp-folder-profiles button");
  expect(profile?.textContent).toContain("Build machine");
  expect(host.querySelector(".acpmux-mp-harness[title^='Build machine']")).toBeNull();
  await act(async () => profile?.click());
  const enable = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-mp-row")].find(
    (button) => !button.closest(".acpmux-mp-folder-profiles") && button.textContent?.includes("Enable"),
  );
  expect(enable).not.toBeUndefined();
  await act(async () => enable?.click());
  expect(enabled).toEqual(["/Users/me/app:machine-profile"]);
});

test("Starred keeps folder models out of the harness rail", async () => {
  dom.window.localStorage.setItem("cmux.model-picker.favorites", JSON.stringify(["machine-model"]));
  await mount({
    harness: "codex",
    extra: [
      {
        id: "machine-profile",
        name: "Build machine",
        models: [{ id: "machine-model", name: "Machine model" }],
        folder: { folder: "/Users/me/app", state: "enabled" },
      },
    ],
  });
  await act(async () => {
    openFullPicker();
  });
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-mp-rail-list [aria-label='Starred']")!.click());
  expect(rows().map((row) => row.dataset.key)).not.toContain("model:machine-model");
});

// Debug Settings' "Allow switching harness in a started chat" (off by default): on, a started
// chat's rail lists every harness, never its own alone, and a pick there starts that harness.
test("with the started-chat harness switch on, the rail lists every harness and a pick crosses", async () => {
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  setComposerSettings({ harnessSwitch: true });
  const { sent } = await mount({ harness: "claude", turnCount: 1, onAddAgent: () => undefined });
  await openOn("Codex");
  const tabs = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].map(
    (button) => button.title.split(" · ")[0],
  );
  expect(tabs.length).toBeGreaterThan(1);
  expect(tabs).toContain("Claude Code");
  expect(host.querySelector(".acpmux-mp-add-harness")).not.toBeNull();
  const astra = rows().find((row) => row.dataset.key === "model:gpt-6-astra")!;
  await act(async () => astra.click());
  expect(sent).toEqual([{ method: "harness", value: "codex/gpt-6-astra" }]);
});

// The same report: from a Codex chat with no message yet, picking Claude started bare `claude`,
// which is signed out on that Mac; its chats run on `claude-sr`. A provider's pick starts the
// profile the person's chats last finished a turn on, never one whose turns only failed.
test("a provider's pick starts the profile this person's chats last completed a turn on", async () => {
  const { sent } = await mount({
    harness: "codex",
    extra: [{ id: "claude-sr", name: "Claude Code (subrouter)", family: "claude" }],
    sessions: [
      { sessionId: "stray", displayTitle: "claude", harness: "claude", updatedAt: 3, worked: false },
      { sessionId: "lane", displayTitle: "cg-next-reds", harness: "claude-sr", updatedAt: 2, worked: true },
    ],
  });
  await openOn("Claude Code");
  const opus = rows().find((row) => row.dataset.key === "model:claude-opus-5-5")!;
  await act(async () => opus.click());
  expect(sent).toEqual([{ method: "harness", value: "claude-sr/claude-opus-5-5" }]);
});

test("a profile that completed turns but no longer runs here never stands in for its provider", async () => {
  const { sent } = await mount({
    harness: "codex",
    extra: [{ id: "claude-sr", name: "Claude Code (subrouter)", family: "claude", unavailable: "sr is not installed" }],
    sessions: [{ sessionId: "lane", displayTitle: "cg-next-reds", harness: "claude-sr", updatedAt: 2, worked: true }],
  });
  await openOn("Claude Code");
  const opus = rows().find((row) => row.dataset.key === "model:claude-opus-5-5")!;
  await act(async () => opus.click());
  expect(sent).toEqual([{ method: "harness", value: "claude/claude-opus-5-5" }]);
});

/// The New Tab page: no chat yet, so a pick starts a deferred switch (`chat.new {deferred}`) that
/// acpmux runs behind the page. The chips are the page's own (App.tsx); the host's actions are
/// the pane's `chat.new` and `chat.model` (App.tsx), on a real HarnessSwitch.
async function mountNewTab(start: { harness: string; folder?: string }) {
  const { createRoot } = await import("react-dom/client");
  const { useSyncExternalStore } = await import("react");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabComposerChips } = await import("../src/agent-session/acpmux/App");
  const { HarnessSwitch, applySwitch, lastOfferedModel } = await import("../src/agent-session/acpmux/harnessSwitch");
  const { newTabStart } = await import("../src/agent-session/acpmux/newtab/chipDefaults");
  const { HarnessProfiles } = await import("../src/agent-session/acpmux/harnessProfiles");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const acpmux = BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
    id: harness.id,
    name: harness.name,
    family: harness.families[0],
    models: harness.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
  const profiles = new HarnessProfiles(() => undefined);
  const sent: { method: string; params: Record<string, unknown> }[] = [];
  const created: string[] = [];
  const models: string[] = [];
  const store = new HarnessSwitch();
  store.connect({
    turnRunning: () => false,
    shown: () => undefined,
    create: async (harness) => {
      created.push(harness);
      return `new-${created.length}`;
    },
    leave: () => undefined,
    open: async (sessionId) => sessionId,
    send: async () => undefined,
    setModel: async (model) => {
      models.push(model);
    },
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  });
  (
    window as unknown as { cmuxAcpmuxActions: Record<string, (params: Record<string, unknown>) => unknown> }
  ).cmuxAcpmuxActions = {
    "chat.new": (params) => {
      sent.push({ method: "chat.new", params });
      const { harness, cwd, deferred, model } = params;
      const picked = model ? String(model) : lastOfferedModel(String(harness), acpmux, cwd ? String(cwd) : undefined);
      return store.switchTo(String(harness), cwd ? String(cwd) : undefined, {
        deferred: deferred === true,
        ...(picked ? { model: picked } : {}),
      });
    },
    "chat.model": (params) => {
      sent.push({ method: "chat.model", params });
      return store.pickModel(String(params.modelId), undefined);
    },
    "chat.mode": async () => undefined,
    "chat.effort": async () => undefined,
    "newTab.remember": async (params) => {
      remembered.push(params);
    },
  };
  const folder = start.folder ?? "/tmp/project";
  const raw: Snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: acpmux,
  } as Snapshot;
  function Page() {
    const view = useSyncExternalStore(store.subscribe, store.view);
    const snapshot = applySwitch(raw, view, acpmux, profiles);
    // NewTabScreen's start: the chip's pick, else the last pick, else the shown agent's default.
    const agents = [start.harness, ...acpmux.map((entry) => entry.id).filter((id) => id !== start.harness)].map(
      (id) => ({ id, name: id }),
    );
    const chips = newTabStart(snapshot, agents, start.harness, folder).snapshot;
    return <NewTabComposerChips snapshot={chips} cwd={folder} />;
  }
  const client = new QueryClient();
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={client}>
        <Page />
      </QueryClientProvider>,
    );
  });
  /// Return on the page: asks the agent the chip shows, in the page's folder (screenActions onAsk).
  const ask = async () => {
    const harness = shownHarness();
    await act(async () => {
      await (window as unknown as { cmuxAcpmuxActions: Record<string, (params: Record<string, unknown>) => unknown> })
        .cmuxAcpmuxActions["chat.new"]!({ harness, cwd: folder });
    });
  };
  const shownHarness = () => store.view().intent?.harness ?? newTabStart(raw, acpmux, start.harness, folder).harness!;
  return { sent, created, models, ask, catalog: BUNDLED_MODEL_CATALOG };
}

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

for (const provider of [
  { harness: "claude", name: "Claude Code", from: "codex" },
  { harness: "codex", name: "Codex", from: "claude" },
]) {
  test(`on a New Tab, every ${provider.name} row lands on the chip, from its own tab and another's`, async () => {
    const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
    const listed = BUNDLED_MODEL_CATALOG.harnesses.find((entry) => entry.id === provider.harness)!.models;
    for (const from of [provider.harness, provider.from]) {
      await mountNewTab({ harness: from });
      await openOn(provider.name);
      const ids = rows().map((row) => row.dataset.key!.slice("model:".length));
      expect(ids.length).toBeGreaterThan(3);
      act(() => root?.unmount());
      for (const id of ids) {
        // Each pick from a fresh page, so no pick rides on the one before it.
        await mountNewTab({ harness: from });
        await openOn(provider.name);
        const row = rows().find((candidate) => candidate.dataset.key === `model:${id}`)!;
        await act(async () => row.click());
        await settle();
        expect({ from, id, chip: chip() }).toEqual({ from, id, chip: listed.find((entry) => entry.id === id)!.name });
        act(() => root?.unmount());
        root = undefined;
      }
    }
  });
}

test("on a New Tab, GPT-6 Astra from Claude Code starts Codex on GPT-6 Astra", async () => {
  const { sent } = await mountNewTab({ harness: "claude" });
  await openOn("Codex");
  const astra = rows().find((row) => row.dataset.key === "model:gpt-6-astra")!;
  await act(async () => astra.click());
  await settle();
  expect(chip()).toBe("GPT-6 Astra");
  expect(sent.find((call) => call.method === "chat.new")?.params).toMatchObject({
    harness: "codex",
    model: "gpt-6-astra",
    deferred: true,
  });
});

test("each provider lists its curated models first; the rest fold under More models, and search reaches all", async () => {
  await mount({ harness: "claude" });
  await act(async () => {
    openFullPicker();
  });
  const names = () => rows().map((row) => row.querySelector(".acpmux-menu-label")!.textContent);
  expect(names()).toEqual(["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]);
  const more = host.querySelector<HTMLButtonElement>(".acpmux-mp-older")!;
  expect(more.textContent).toContain("More models");
  await act(async () => more.click());
  expect(names()).toContain("Opus 4.8");
  await openOn("Codex");
  await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-mp-older")!.click());
  expect(names().slice(0, 3)).toEqual(["GPT-6.1 Sol", "GPT-6 Astra", "GPT-6 Luna"]);
  const search = host.querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]')!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(search, "opus 4.6");
    search.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  expect(names()).toContain("Opus 4.6");
});

test("hovering a provider in the rail keeps the list; a click switches it", async () => {
  await mount({ harness: "claude" });
  await act(async () => {
    openFullPicker();
  });
  const first = () => rows()[0]?.dataset.key;
  expect(first()).toBe("model:claude-fable-5-1");
  const codex = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].find(
    (button) => button.title.split(" · ")[0] === "Codex",
  )!;
  await act(async () => {
    codex.dispatchEvent(new dom.window.PointerEvent("pointerover", { bubbles: true }));
    codex.dispatchEvent(new dom.window.PointerEvent("pointerenter", { bubbles: false }));
    codex.dispatchEvent(new dom.window.MouseEvent("mouseover", { bubbles: true }));
  });
  expect(first()).toBe("model:claude-fable-5-1");
  await act(async () => codex.click());
  expect(first()).toBe("model:gpt-6.1-sol");
});

test("a typed combo for another provider starts it on that model, then sets its effort", async () => {
  const { sent } = await mount({ harness: "claude" });
  await act(async () => {
    openFullPicker();
  });
  const search = host.querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]')!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(search, "astra high");
    search.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    search.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Enter" }));
  });
  await settle();
  expect(sent).toEqual([
    { method: "harness", value: "codex/gpt-6-astra" },
    { method: "effort", value: "high" },
  ]);
});

test("Add harness… shows only where the Harnesses page can open (never in the Quick Composer)", async () => {
  const { registerHarnessesPage } = await import("../src/agent-session/acpmux/harnesses/harnessesPage");
  await mountNewTab({ harness: "claude" });
  await act(async () => {
    openFullPicker();
  });
  // No pane that can show the page is mounted (the Quick Composer registers none).
  expect(host.querySelector(".acpmux-mp-add-harness")).toBeNull();
  const opened: string[] = [];
  let unregister = () => {};
  await act(async () => {
    unregister = registerHarnessesPage(() => opened.push("harnesses"));
  });
  const add = host.querySelector<HTMLButtonElement>(".acpmux-mp-add-harness");
  expect(add).not.toBeNull();
  await act(async () => add!.click());
  expect(opened).toEqual(["harnesses"]);
  act(() => unregister());
});

// Review of #20606: with no model row left, Add harness… was current by default, so Return on a
// search with no match left the chat for the Harnesses page.
test("Return on a search with no match stays put; an arrow onto Add harness… then opens it", async () => {
  const { registerHarnessesPage } = await import("../src/agent-session/acpmux/harnesses/harnessesPage");
  const opened: string[] = [];
  const unregister = registerHarnessesPage(() => opened.push("harnesses"));
  try {
    await mountNewTab({ harness: "claude" });
    await act(async () => {
      openFullPicker();
    });
    const search = host.querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]')!;
    const key = (name: string) =>
      act(async () => {
        search.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
      });
    await act(async () => {
      Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(search, "zzz");
      search.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
    expect(rows()).toEqual([]);
    const add = host.querySelector<HTMLButtonElement>(".acpmux-mp-add-harness")!;
    expect(add.getAttribute("aria-selected")).not.toBe("true");
    await key("Enter");
    expect(opened).toEqual([]);
    await key("ArrowDown");
    expect(add.getAttribute("aria-selected")).toBe("true");
    await key("Enter");
    expect(opened).toEqual(["harnesses"]);
  } finally {
    act(() => unregister());
  }
});

async function pickOnNewTab(from: string, provider: string, id: string, folder?: string) {
  await mountNewTab({ harness: from, ...(folder ? { folder } : {}) });
  await openOn(provider);
  const row = rows().find((candidate) => candidate.dataset.key === `model:${id}`)!;
  await act(async () => row.click());
  await settle();
  act(() => root?.unmount());
  root = undefined;
}

test("the last pick is the model of the next New Tab, after a restart too, and the chat starts on it", async () => {
  await pickOnNewTab("claude", "Codex", "gpt-6-astra");
  // The app keeps the pick: an agent page's own storage ends with the launch.
  expect(remembered.at(-1)).toEqual({ agent: "codex", model: "gpt-6-astra", folder: "/tmp/project" });
  // A new tab: the page and its switch are new; only what was remembered carries over.
  const next = await mountNewTab({ harness: "claude" });
  expect(chip()).toBe("GPT-6 Astra");
  act(() => root?.unmount());
  root = undefined;
  // A restart: the page's storage is gone (its web view's store is not persistent), and the
  // New Tab context brings back what the app kept.
  dom.window.localStorage.clear();
  const { newTabHost } = await import(`../src/agent-session/acpmux/NewTabPage?restart=${Date.now()}`);
  newTabHost({
    newTab: {
      lastPicks: {
        global: { harness: "codex", model: "gpt-6-astra" },
        folders: [{ folder: "/tmp/project", harness: "codex", model: "gpt-6-astra" }],
      },
    },
  });
  const tab = await mountNewTab({ harness: "claude" });
  expect(chip()).toBe("GPT-6 Astra");
  await tab.ask();
  await settle();
  expect({ created: tab.created, models: tab.models }).toEqual({ created: ["codex"], models: ["gpt-6-astra"] });
  expect(next.created).toEqual([]);
});

test("a context built before this page's pick does not take the pick back", async () => {
  await pickOnNewTab("claude", "Codex", "gpt-6-astra");
  // The early New Tab context (or a reloaded page's) arrives after the pick with the app's older copy.
  const { newTabHost } = await import("../src/agent-session/acpmux/NewTabPage");
  newTabHost({ newTab: { lastPicks: { global: { harness: "claude", model: "claude-haiku-5-5" }, folders: [] } } });
  await mountNewTab({ harness: "claude" });
  expect(chip()).toBe("GPT-6 Astra");
});

test("a folder keeps its own last pick; other folders take the latest pick anywhere", async () => {
  await pickOnNewTab("claude", "Codex", "gpt-6-astra", "/work/a");
  await pickOnNewTab("codex", "Claude Code", "claude-opus-5-5", "/work/b");
  for (const [folder, name] of [
    ["/work/a", "GPT-6 Astra"],
    ["/work/b", "Claude Opus 5.5"],
    ["/work/c", "Claude Opus 5.5"],
  ] as const) {
    await mountNewTab({ harness: "claude", folder });
    expect({ folder, chip: chip() }).toEqual({ folder, chip: name });
    act(() => root?.unmount());
    root = undefined;
  }
});

test("the rail lists the harnesses set up here; one acpmux cannot run stays off it", async () => {
  await mount({
    harness: "claude",
    extra: [{ id: "grok", name: "Grok", unavailable: "grok: command not found" }],
  });
  await act(async () => {
    openFullPicker();
  });
  const rail = () => [...host.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].map((tab) => tab.title);
  expect(rail().some((title) => title.startsWith("Grok"))).toBe(false);
  expect(rail().some((title) => title.startsWith("Claude Code"))).toBe(true);
});

test("a harness whose model probe alone failed stays on the rail", async () => {
  await mount({
    harness: "claude",
    extra: [{ id: "grok", name: "Grok", unavailable: "model list timed out", probeFailed: true }],
  });
  await act(async () => {
    openFullPicker();
  });
  const rail = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].map((tab) => tab.title);
  expect(rail.some((title) => title.startsWith("Grok"))).toBe(true);
});

test("a remembered model the harness no longer offers is neither drawn nor asked for", async () => {
  dom.window.localStorage.setItem(
    "cmux.acpmux.lastPick",
    JSON.stringify({ global: { harness: "claude", model: "claude-opus-3" } }),
  );
  const tab = await mountNewTab({ harness: "claude" });
  expect(chip()).not.toContain("opus-3");
  await tab.ask();
  await settle();
  expect(tab.created).toEqual(["claude"]);
  expect(tab.models).toEqual([]);
});

// A model's ☆ says what a click does (it adds the model to Starred or takes it off) and carries
// its state as aria-pressed, so the glyph is not the only cue.
test("a model's star button names its action in a tooltip and its state as pressed", async () => {
  await mount({ harness: "claude" });
  await openOn("Codex");
  const star = () => host.querySelector<HTMLButtonElement>(".acpmux-mp-favorite")!;
  expect(star().getAttribute("aria-label")).toStartWith("Starred: ");
  expect([star().title, star().getAttribute("aria-pressed")]).toEqual(["Add to Starred", "false"]);
  await act(async () => star().click());
  expect([star().title, star().getAttribute("aria-pressed")]).toEqual(["Remove from Starred", "true"]);
});
