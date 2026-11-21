// l10n-allow-file: test fixtures.
// The composer's model chip names the model with its version ("Opus 5.5"), also for a chat on an
// alias ("opus") whose harness names it by its family alone ("Opus").
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
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

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

const EFFORT = {
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "medium",
  options: [
    { value: "default", name: "Default" },
    { value: "low", name: "Low" },
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
  ],
};

// Claude Code's own aliases as acpmux names them until Claude Code's list answers.
const MODELS = [
  { id: "default", name: "Default (Claude Code's choice)" },
  { id: "opus", name: "Opus" },
  { id: "opus[1m]", name: "Opus · 1M context" },
  { id: "opusplan", name: "Opus plan · Sonnet execute" },
  { id: "sonnet", name: "Sonnet" },
  { id: "claude-opus-5-5", name: "Opus 5.5" },
  { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
];

/// A Claude chat that asked for `model` and whose model option reports it runs `runs`.
async function mount(model: string, runs: string) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const catalog = [
    { id: "claude", name: "Claude Code", family: "claude", models: MODELS },
  ] as unknown as Snapshot["catalog"];
  const summary = {
    sessionId: "s-claude",
    harness: "claude",
    family: "claude",
    model,
    turnCount: 1,
    configOptions: [
      {
        id: "model",
        name: "Model",
        category: "model",
        currentValue: runs,
        options: MODELS.map((row) => ({ value: row.id, name: row.name })),
      },
      EFFORT,
    ],
  };
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [{ id: "u1", kind: "user", text: "hi" }],
    sessions: [{ sessionId: "s-claude", harness: "claude", turnCount: 1 }],
    sessionId: "s-claude",
    connection: "connected",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary,
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

const chip = () => (host.querySelector<HTMLElement>(".acpmux-model .acpmux-model-name")?.textContent ?? "").trim();
const button = () =>
  (host.querySelector<HTMLElement>(".acpmux-model .acpmux-picker-button, .acpmux-model [data-menu]")?.textContent ?? "")
    .replace(/\s+/g, " ")
    .trim();

// Leo 2026-11-02: "WHY DOES IT ONLY SHOW OPUS" over a chip reading "Opus Medium" (it read
// "Opus 5.5 Medium" before). A chat that asked for Claude Code's `opus` alias reports the alias as
// its model; the chip named it by the alias's own name, "Opus", never the release it runs.
test("a chat on the opus alias names the release its model option reports: Opus 5.5 Medium", async () => {
  await mount("opus", "claude-opus-5-5");
  expect(chip()).toBe("Opus 5.5");
  expect(button()).toMatch(/Opus 5\.5 ?Medium/);
  expect(button()).not.toMatch(/^Opus ?Medium/);
});

test("before its session reports the release, the alias is named as the release it last ran here", async () => {
  await mount("opus", "claude-opus-5-5");
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  await mount("opus", "opus");
  expect(chip()).toBe("Opus 5.5");
});

test("a chat on the 1M opus alias keeps its context variant beside the version", async () => {
  await mount("opus[1m]", "claude-opus-5-5[1m]");
  expect(chip()).toMatch(/^Opus 5\.5 .*1M/);
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  await mount("opus[1m]", "claude-opus-5-5");
  expect(chip()).toMatch(/^Opus 5\.5 .*1M/);
});

test("an alias whose name says more than its family keeps its name", async () => {
  await mount("opusplan", "claude-opus-5-5");
  expect(chip()).toContain("plan");
});

test("a chat on a release keeps its name", async () => {
  await mount("claude-sonnet-5-5", "claude-sonnet-5-5");
  expect(chip()).toBe("Sonnet 5.5");
});

test("aliasNamedAsRelease swaps only a bare family", async () => {
  const { aliasNamedAsRelease } = await import("../src/agent-session/acpmux/composerPickerModel");
  expect(aliasNamedAsRelease("Opus", "Opus 5.5")).toBe("Opus 5.5");
  expect(aliasNamedAsRelease("Opus", "Claude Opus 5.5")).toBe("Claude Opus 5.5");
  expect(aliasNamedAsRelease("Opus · 1M context", "Opus 5.5 · 1M context")).toBe("Opus 5.5 · 1M context");
  expect(aliasNamedAsRelease("Opus · 1M context", "Opus 5.5")).toBe("Opus 5.5 · 1M context");
  expect(aliasNamedAsRelease("Opus plan · Sonnet execute", "Opus 5.5")).toBe("Opus plan · Sonnet execute");
  expect(aliasNamedAsRelease("Sonnet", "Opus 5.5")).toBe("Sonnet");
});
