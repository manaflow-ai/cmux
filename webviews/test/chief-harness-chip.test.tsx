// l10n-allow-file: test fixtures.
// The agent chat on the Chief harness (acpmux `chief`, `cmux chief acp`): the Chief picks its own
// engine, so its chat lists no models. Its chip says whose chat it is, and its picker panel offers
// no model list, refresh or account (user, 2026-10-30).
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

async function mountChief(summary: Record<string, unknown> | undefined) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const catalog = [
    // acpmux lists a harness that reports no models with its agent's default only.
    {
      id: "chief",
      name: "Chief",
      family: "chief",
      kind: "acp",
      models: [{ id: "default", name: "default (agent's choice)" }],
    },
    {
      id: "claude",
      name: "Claude Code",
      family: "claude",
      models: [{ id: "claude-opus-5-5", name: "Claude Opus 5.5" }],
    },
  ] as unknown as Snapshot["catalog"];
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: summary ? [{ id: "u1", kind: "user", text: "hi" }] : [],
    sessions: summary ? [{ sessionId: "s-chief", harness: "chief", turnCount: 1 }] : [],
    sessionId: summary ? "s-chief" : undefined,
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

const modelButton = () => host.querySelector<HTMLElement>('[data-menu="Model"]');
const chipText = () => modelButton()?.getAttribute("title") ?? modelButton()?.textContent ?? "";

test("a running chat on the Chief harness names the Chief on its model chip", async () => {
  await mountChief({ sessionId: "s-chief", harness: "chief", turnCount: 1 });
  expect(chipText()).toBe("Chief");
  expect(modelButton()?.textContent ?? "").toContain("Chief");
});

test("a chat on a harness with models never takes the harness name as its model", async () => {
  await mountChief({ sessionId: "s-c", harness: "claude", turnCount: 1 });
  expect(chipText()).not.toBe("Claude Code");
});

test("the Chief's picker panel offers no model list, refresh or account", async () => {
  await mountChief({ sessionId: "s-chief", harness: "chief", turnCount: 1 });
  await act(async () => {
    modelButton()!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
  const text = dom.window.document.body.textContent ?? "";
  expect(text).toContain("Chief");
  expect(text).not.toContain("No models yet");
  expect(text).not.toContain("Refresh");
  expect(text).not.toContain("Account");
  expect(text).not.toContain("CLI login");
});
