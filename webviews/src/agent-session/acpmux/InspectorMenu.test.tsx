import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
// A silent console: jsdom has no canvas, so text measurement logs and falls back to row estimates.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
/// Every ResizeObserver callback, so a test can report a viewport resize.
const resizeCallbacks: (() => void)[] = [];
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "customElements",
    "Node",
    "MutationObserver",
    "IntersectionObserver",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  // Code blocks and edit diffs watch the pane's theme attribute.
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    constructor(callback: () => void) {
      resizeCallbacks.push(callback);
    }
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// The changes view renders @pierre/diffs and @pierre/trees web components, which reach for
// DOM classes (HTMLTemplateElement, SVGElement, ...) by their global names.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Element|Event|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent|Shadow|Document|Mutation|getComputedStyle)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react").then((react) => ({
  act: react.act,
  createElement: react.createElement,
}));
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");



test("the chat menu opens the wire inspector and Escape returns focus to the menu", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    const menu = dom.window.document.querySelector<HTMLButtonElement>('button[aria-label="Chat actions"]')!;
    expect(menu).not.toBeNull();
    await act(async () => {
      menu.click();
      await new Promise((resolve) => setTimeout(resolve, 170));
    });
    const row = [...dom.window.document.querySelectorAll<HTMLElement>('[role="menuitem"]')]
      .find((item) => item.textContent?.includes("ACP inspector"));
    expect(row).toBeDefined();
    await act(async () => row!.click());
    expect(dom.window.document.querySelector(".acpmux-inspector")).not.toBeNull();
    await act(async () => {
      dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });
    expect(dom.window.document.querySelector(".acpmux-inspector")).toBeNull();
    expect(dom.window.document.activeElement).toBe(menu);
  } finally {
    await act(async () => root.unmount());
  }
});
