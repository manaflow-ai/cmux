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

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

/// The pane of chat `s-opus` while acpmux has not attached it yet (its loading state: a spinner over
/// an empty transcript): the snapshot names the selected chat but has no summary. The picker's
/// first harness is cmux Harness, whose start model is Sonnet 4.5 at Medium, the stand-in the chip
/// used to show (#28884). `listed` is the chat's row in the chat list, when acpmux listed it.
/// `summary` is a summary the pane already has (a New Tab's chips: newTabStart, no session id).
async function mountOpening(listed?: Record<string, unknown>, summary?: Record<string, unknown>) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const catalog = [
    {
      id: "cmux-harness",
      name: "cmux Harness (Pi)",
      family: "cmux-harness",
      models: [{ id: "anthropic/claude-sonnet-4-5", name: "Claude Sonnet 4.5" }],
      start: { model: "anthropic/claude-sonnet-4-5", effort: "medium" },
    },
    {
      id: "claude",
      name: "Claude Code",
      family: "claude",
      models: [
        { id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5" },
        { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
      ],
      start: { model: "claude-sonnet-4-5", effort: "medium" },
    },
  ] as Snapshot["catalog"];
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: listed ? [{ sessionId: "s-opus", ...listed }] : [],
    sessionId: "s-opus",
    connection: "connected",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    ...(summary ? { summary } : {}),
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, {});
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
}

const modelButton = () => host.querySelector('[data-menu="Model"]');

// #28884: a loading Opus 5.5 chat's composer read "Sonnet 4.5 Medium", the picker's first
// harness's start model and level, before acpmux attached the chat.
test("a loading chat's model chip names the model and effort its listed row reports", async () => {
  await mountOpening({ harness: "claude", model: "claude-opus-5-5", effort: "high", turnCount: 4 });
  expect(modelButton()?.getAttribute("title")).toBe("Claude Opus 5.5");
  const text = host.textContent ?? "";
  expect(text).not.toContain("Sonnet");
  expect(text).not.toContain("Med");
  expect(text).toContain("High");
});

// No row to read it from: the chip holds the neutral "Model", never another harness's default.
test("a loading chat that is not listed yet names no made-up model", async () => {
  await mountOpening();
  expect(modelButton()?.getAttribute("title") ?? modelButton()?.textContent).toBe("Model");
  expect(host.textContent ?? "").not.toContain("Sonnet");
});

// A listed row with no model (an acpmux that has not reported it) also waits rather than guess.
test("a loading chat whose row names no model keeps the placeholder", async () => {
  await mountOpening({ harness: "claude", turnCount: 2 });
  expect(modelButton()?.getAttribute("title") ?? modelButton()?.textContent).toBe("Model");
  expect(host.textContent ?? "").not.toContain("Sonnet");
  expect(host.textContent ?? "").not.toContain("Med");
});

// A chat acpmux started for a New Tab before its first prompt, where the person then picked Opus:
// its row's model is the truth, not the New Tab's prediction.
test("a loading unsent chat names the model its listed row reports", async () => {
  await mountOpening({ harness: "claude", model: "claude-opus-5-5", unsent: true, turnCount: 0 });
  expect(modelButton()?.getAttribute("title")).toBe("Claude Opus 5.5");
});

// The New Tab page stays up while a recent chat it opened attaches: its chips stay the New Tab's
// own (its agent's start model), never the picked chat's row.
test("a New Tab waiting on a picked chat keeps its own chips", async () => {
  await mountOpening(
    { harness: "claude", model: "claude-opus-5-5", effort: "high", turnCount: 4 },
    { sessionId: "", harness: "claude", turnCount: 0 },
  );
  expect(modelButton()?.getAttribute("title")).toBe("Claude Sonnet 4.5");
  expect(host.textContent ?? "").not.toContain("Opus");
});
