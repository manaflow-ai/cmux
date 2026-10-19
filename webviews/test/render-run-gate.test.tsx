// Lucas 2026-10-19: a page from history waits for Run, but its card still offered Open preview,
// which showed the page's source in the side panel, and Run was a small text button in the card's
// title line. A waiting card now has no preview button and one large Run target where the page
// will show; Open preview comes once the page runs.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://127.0.0.1:4276/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  addEventListener: dom.window.addEventListener.bind(dom.window),
  removeEventListener: dom.window.removeEventListener.bind(dom.window),
  document: dom.window.document,
  location: dom.window.location,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// The code card's highlighter (@pierre/diffs) defines its elements, which read DOM constructors, on import.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;
afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("a waiting page has one large Run and no Open preview; preview comes once it runs", async () => {
  const { createRoot } = await import("react-dom/client");
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  const { ArtifactContext } = await import("../src/agent-session/acpmux/conversation/artifactPreview");
  const opened: unknown[] = [];
  root = createRoot(host);
  act(() =>
    root!.render(
      <ArtifactContext.Provider value={(artifact) => opened.push(artifact)}>
        <RenderCard call={{ html: "<title>Depreciation</title><p>Chart</p>" }} />
      </ArtifactContext.Provider>,
    ),
  );
  const preview = () => host.querySelector('[aria-label="Open preview"]');
  expect(host.querySelector("iframe")).toBeNull();
  expect(preview()).toBeNull();
  const gate = host.querySelector<HTMLButtonElement>(".acpmux-render-card-gate");
  expect(gate?.textContent).toBe("Show visualization");
  // The title line carries no second, small Run.
  expect(host.querySelector(".acpmux-render-card-head button")).toBeNull();
  act(() => gate!.click());
  expect(host.querySelector("iframe")).not.toBeNull();
  expect(host.querySelector(".acpmux-render-card-gate")).toBeNull();
  expect(preview()).not.toBeNull();
});

// Lucas 2026-10-19: a render is a visualization, not a preview of something else.
test("a page with no title is called a visualization", async () => {
  const { createRoot } = await import("react-dom/client");
  const { RenderCard } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  act(() => root?.unmount());
  root = createRoot(host);
  act(() => root!.render(<RenderCard call={{ html: "<p>Chart</p>" }} />));
  expect(host.querySelector(".acpmux-render-card-head")?.textContent).toContain("Visualization");
  expect(host.querySelector(".acpmux-render-card-gate")?.textContent).toBe("Show visualization");
});
