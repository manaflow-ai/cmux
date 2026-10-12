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
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Sent = { method: "model" | "harness"; value: string };

async function mount(start: { harness: string }) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  // acpmux's harness list: what `_acpmux/models` reports for each catalog harness.
  const acpmux: Snapshot["catalog"] = BUNDLED_MODEL_CATALOG.harnesses.map((harness) => ({
    id: harness.id,
    name: harness.name,
    family: harness.families[0],
    models: harness.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
  const sent: Sent[] = [];
  let session = 0;
  function Host() {
    const [state, setState] = useState({ sessionId: `s${session}`, harness: start.harness, model: "default" });
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
      summary: { sessionId: state.sessionId, harness: state.harness, model: state.model, turnCount: 1 },
    } as Snapshot;
    const picker = usePickerCatalog(snapshot.catalog, { harness: state.harness });
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={(model) => {
          sent.push({ method: "model", value: model });
          setState((current) => ({ ...current, model }));
        }}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={(harness, model) => {
          sent.push({ method: "harness", value: model ? `${harness}/${model}` : harness });
          session += 1;
          setState({ sessionId: `s${session}`, harness, model: model ?? "default" });
        }}
        showPlan={false}
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

const chip = () => host.querySelector(".acpmux-model-name")?.textContent ?? "";

async function openOn(harnessName: string) {
  if (!host.querySelector(".acpmux-mp"))
    await act(async () => {
      host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click();
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

test("a row of another provider starts that provider on that row's model", async () => {
  const { sent } = await mount({ harness: "claude" });
  await openOn("Codex");
  const astra = rows().find((row) => row.dataset.key === "model:gpt-6-astra")!;
  await act(async () => astra.click());
  // One switch carries the model: the new chat starts on it, with no second model request.
  expect(sent).toEqual([{ method: "harness", value: "codex/gpt-6-astra" }]);
  expect(chip()).toBe("GPT-6 Astra");
});

/// The New Tab page: no chat yet, so a pick starts a deferred switch (`chat.new {deferred}`) that
/// acpmux runs behind the page. The chips are the page's own (App.tsx); the host's actions are
/// the pane's `chat.new` and `chat.model` (App.tsx), on a real HarnessSwitch.
async function mountNewTab(start: { harness: string }) {
  const { createRoot } = await import("react-dom/client");
  const { useSyncExternalStore } = await import("react");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabComposerChips } = await import("../src/agent-session/acpmux/App");
  const { HarnessSwitch, applySwitch, defaultModel } = await import("../src/agent-session/acpmux/harnessSwitch");
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
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  });
  (window as unknown as { cmuxAcpmuxActions: Record<string, (params: Record<string, unknown>) => unknown> })
    .cmuxAcpmuxActions = {
    "chat.new": (params) => {
      sent.push({ method: "chat.new", params });
      const { harness, cwd, deferred, model } = params;
      return store.switchTo(String(harness), cwd ? String(cwd) : undefined, {
        deferred: deferred === true,
        ...(model ? { model: String(model) } : {}),
      });
    },
    "chat.model": (params) => {
      sent.push({ method: "chat.model", params });
      return store.pickModel(String(params.modelId), undefined);
    },
    "chat.mode": async () => undefined,
    "chat.effort": async () => undefined,
  };
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
    // NewTabScreen's chip snapshot: the shown agent and its default model until a pick.
    const chips = snapshot.summary?.harness
      ? snapshot
      : {
          ...snapshot,
          summary: {
            sessionId: "",
            turnCount: 0,
            harness: start.harness,
            model: defaultModel(start.harness, acpmux, profiles) ?? "default",
          },
        };
    return <NewTabComposerChips snapshot={chips} cwd="/tmp/project" />;
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
  return { sent, catalog: BUNDLED_MODEL_CATALOG };
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
    host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click();
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
    host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click();
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
