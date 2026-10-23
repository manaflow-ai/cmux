// Leo 2026-10-12, on nightly-next: a New Tab's model picker listed every Claude model, not the
// curated few. The chip starts on the catalog's default for Claude Code (Sonnet 5), which is not one
// of them, and the picker opened its More models fold to show it; Fable 5.1, which Claude Code
// offers by its alias (`fable`), never matched the curated list. At the New Tab boundary: the
// real screen and its chips, with the catalog acpmux answered on a Mac with Claude Code. Since Leo
// 2026-10-20 a click on the model button opens its compact menu (model-menu-compact.test.tsx); the
// full picker checked here is the one More models and the "Model" opener (pickerOpeners.ts) show.
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
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  // What Claude Code itself reports (acpmux's probe on a capture Mac, 2026-10-12): Fable 5.1 by
  // its alias.
  const acpmux: Snapshot["catalog"] = [
    {
      id: "claude",
      name: "Claude Code",
      family: "claude",
      models: [
        { id: "default", name: "Default (Claude Code's choice)" },
        { id: "claude-opus-5-5", name: "Claude Opus 5.5", shortName: "Opus 5.5" },
        { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", shortName: "Sonnet 5.5" },
        { id: "claude-haiku-5-5", name: "Claude Haiku 5.5", shortName: "Haiku 5.5" },
        { id: "fable", name: "Fable 5.1" },
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
  // The chip draws the name without the vendor its mark shows; the title keeps the full name.
  expect(host.querySelector(".acpmux-model-name")?.textContent).toBe("Opus 5.5");
  expect(host.querySelector('[data-menu="Model"]')?.getAttribute("title")).toBe("Claude Opus 5.5");
  await act(async () => void openPicker("Model"));
  const rows = () =>
    [...host.querySelectorAll('[data-key^="model:"] .acpmux-menu-label')].map((row) => row.textContent);
  // The chip names the catalog's default, Opus 5.5 (cx-qtmy2): a top model, so nothing joins the list.
  expect(rows()).toEqual(["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]);
  const more = host.querySelector<HTMLButtonElement>(".acpmux-mp-older")!;
  expect(more.getAttribute("aria-expanded")).toBe("false");
  // Fable 5.1 runs by the alias Claude Code offers. The chip's row is checked, and opening the fold
  // lists every other model under it once.
  expect(host.querySelector('[data-key="model:fable"] .acpmux-menu-label')?.textContent).toBe("Fable 5.1");
  expect(host.querySelector('[data-key="model:claude-opus-5-5"]')?.getAttribute("aria-checked")).toBe("true");
  await act(async () => more.click());
  const all = rows();
  expect(all.slice(0, 4)).toEqual(["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]);
  expect(all).toContain("Opus 4.8");
  expect(all.filter((name) => name === "Sonnet 5")).toHaveLength(1);
});
