// Leo 2026-10-12, on nightly-next: a New Tab's model picker listed every Claude model, not the
// curated few. The chip starts on the catalog's default for Claude Code (Sonnet 5), which is not one
// of them, and the picker opened its More models fold to show it. At the New Tab boundary: the
// real screen and its chips, with the catalog acpmux answered on a Mac with Claude Code.
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
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
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

test("a New Tab's picker lists the curated models and the chip's own, with the rest folded", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { NewTabComposerChips } = await import("../src/agent-session/acpmux/App");
  const { noChat } = await import("../src/gallery/fixtures/acpmux");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const model = (id: string, name: string) => ({ id, name });
  const acpmux: Snapshot["catalog"] = [
    {
      id: "claude",
      name: "Claude Code",
      family: "claude",
      models: [
        model("default", "Default (Claude Code's choice)"),
        model("claude-fable-5-1", "Claude Fable 5.1"),
        model("claude-opus-5-5", "Claude Opus 5.5"),
        model("claude-opus-4-8", "Claude Opus 4.8"),
        model("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        model("claude-sonnet-5", "Claude Sonnet 5"),
        model("claude-haiku-5-5", "Claude Haiku 5.5"),
      ],
    },
  ];
  const noop = () => undefined;
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <NewTabScreen
          snapshot={{ ...noChat(), catalog: acpmux }}
          chips={NewTabComposerChips}
          onAsk={noop}
          onOpen={noop}
          onSearch={noop}
          onShell={noop}
          onJump={noop}
          onOpenSession={noop}
          onShowAll={noop}
        />
      </QueryClientProvider>,
    );
  });
  expect(host.querySelector(".acpmux-model-name")?.textContent).toBe("Claude Sonnet 5");
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  const rows = () =>
    [...host.querySelectorAll('[data-key^="model:"] .acpmux-menu-label')].map((row) => row.textContent);
  expect(rows()).toEqual(["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Sonnet 5"]);
  const more = host.querySelector<HTMLButtonElement>(".acpmux-mp-older")!;
  expect(more.getAttribute("aria-expanded")).toBe("false");
  // Its row is checked, and opening the fold lists every other model under it once.
  expect(host.querySelector('[data-key="model:claude-sonnet-5"]')?.getAttribute("aria-checked")).toBe("true");
  await act(async () => more.click());
  const all = rows();
  expect(all.slice(0, 5)).toEqual(["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Sonnet 5"]);
  expect(all).toContain("Opus 4.8");
  expect(all.filter((name) => name === "Sonnet 5")).toHaveLength(1);
});
