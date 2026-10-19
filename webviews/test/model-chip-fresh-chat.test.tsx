// l10n-allow-file: test fixtures.
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
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

/// A chat on `harness` whose session has not reported a model yet: the summary names its agent
/// only (`summary` adds to it). Returns the name of the model a New Tab on `harness` asks the chat
/// to start on (`newTabStart`, `useNewTabChipModel`), for the same storage and catalogs.
async function mountChat(harness: string, summary: Record<string, unknown> = {}) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const { newTabStart, useNewTabChipModel } = await import("../src/agent-session/acpmux/newtab/chipDefaults");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const catalog = BUNDLED_MODEL_CATALOG.harnesses.map((entry) => ({
    id: entry.id,
    name: entry.name,
    family: entry.families[0],
    models: entry.models.map((model) => ({ id: model.id, name: model.name })),
  })) as Snapshot["catalog"];
  const bare = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
  } as Snapshot;
  const snapshot = { ...bare, summary: { sessionId: "", harness, turnCount: 0, ...summary } } as Snapshot;
  const newTab = newTabStart(bare, [{ id: harness, name: harness }], harness, undefined).snapshot;
  let asked: string | undefined;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, { harness });
    asked = useNewTabChipModel(newTab);
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
      />
    );
  }
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    );
  });
  const entry = BUNDLED_MODEL_CATALOG.harnesses.find((candidate) => candidate.id === harness)!;
  expect(asked).toBeDefined();
  return entry.models.find((model) => model.id === asked)?.name ?? asked;
}

// The model the chip names, in full: its title (the visible name drops the vendor its mark draws).
const chip = () => host.querySelector('[data-menu="Model"]')?.getAttribute("title") ?? "";

// Dogfood run 5 (cx-21jvw): a chat started from a New Tab read "Model" on its chip until the
// session reported Opus 5.5. Before that, the chip names the model the New Tab started it on
// (cx-e2aa's chip rule), never a bare "Model" or another model.
test("a fresh chat's model chip names the model its New Tab started it on", async () => {
  const asked = await mountChat("claude");
  expect(chip()).toBe(asked!);
});

test("after a pick, a fresh chat's chip names the picked model, as the New Tab asked", async () => {
  const { rememberPick } = await import("../src/agent-session/acpmux/lastPick");
  rememberPick({ harness: "codex", model: "gpt-5.5" });
  const asked = await mountChat("codex");
  expect(chip()).toBe(asked!);
  expect(chip()).not.toBe("Model");
});

// A chat that already ran turns, or runs on another machine, may run a model other than this
// Mac's start rule names: its chip waits for the session rather than guess.
test("a resumed or remote chat's chip does not guess a model", async () => {
  await mountChat("claude", { sessionId: "s-old", turnCount: 3 });
  expect(chip()).toBe("Model");
  act(() => root?.unmount());
  await mountChat("claude", { host: "devbox" });
  expect(chip()).toBe("Model");
});
