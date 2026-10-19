import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

/// Opening Chat summary (Thread details) after it was hidden drew more hooks than the hidden card
/// did, and React took the whole pane down (Lucas 2026-10-18).
test("the summary card opens after being hidden without breaking the pane", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { SummaryCard } = await import("../src/agent-session/acpmux/summary/SummaryCard");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  const errors: unknown[] = [];
  const card = (shown: boolean) => ({
    shown,
    column: false,
    reserve: false,
    collapsed: false,
    toggle() {},
    show() {},
    close() {},
    fold() {},
  });
  const draw = (shown: boolean) => (
    <UiProvider container={rootElement}>
      <SummaryCard
        card={card(shown)}
        rows={[]}
        subagents={{ views: undefined, current: undefined, asks: new Set(), onOpen() {} }}
      />
    </UiProvider>
  );
  const onError = (error: unknown) => errors.push(error);
  const saved = console.error;
  console.error = onError;
  try {
    await act(async () => root.render(draw(false)));
    await act(async () => root.render(draw(true)));
  } finally {
    console.error = saved;
  }
  expect(errors.filter((error) => String(error).includes("hooks"))).toEqual([]);
  expect(rootElement.textContent).not.toBe("");
  await act(async () => root.unmount());
});
