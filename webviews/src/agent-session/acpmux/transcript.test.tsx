import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "./model";

// A silent console: jsdom has no canvas, so text measurement logs and falls back to row estimates.
const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, virtualConsole: new VirtualConsole() });
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(["window", "document", "navigator", "HTMLElement", "ResizeObserver", "requestAnimationFrame", "cancelAnimationFrame", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  ResizeObserver: class { observe() {} disconnect() {} },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react").then((react) => ({ act: react.act, createElement: react.createElement }));
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("./App");
const { acpmuxPerf } = await import("./perf");

const rows: AcpmuxRow[] = Array.from({ length: 200 }, (_, index) => ({ id: `row-${index}`, version: 1, at: index, kind: index % 2 ? "assistant" : "user", text: `message ${index}` }));

describe("acpmux virtual transcript", () => {
  test("re-renders that keep rows and width reuse the conversation layout", async () => {
    let layouts = 0;
    const addLayout = acpmuxPerf.addLayout.bind(acpmuxPerf);
    acpmuxPerf.enabled = true;
    acpmuxPerf.addLayout = (ms: number) => { layouts += 1; addLayout(ms); };
    const root = createRoot(dom.window.document.getElementById("root")!);
    const onToggleActivity = () => {};
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows, onToggleActivity, expanded: new Set<string>() })));
      const afterMount = layouts;
      expect(afterMount).toBeGreaterThan(0);
      // A scroll or an expansion toggle re-renders with the same rows and width.
      for (let pass = 0; pass < 5; pass += 1) {
        await act(async () => root.render(createElement(VirtualTranscript, { rows, onToggleActivity, expanded: new Set<string>([`row-${pass}`]) })));
      }
      expect(layouts).toBe(afterMount);
      // New rows still lay out again.
      await act(async () => root.render(createElement(VirtualTranscript, { rows: [...rows, { id: "row-new", version: 1, at: 999, kind: "assistant", text: "new" }], onToggleActivity, expanded: new Set<string>() })));
      expect(layouts).toBeGreaterThan(afterMount);
    } finally {
      await act(async () => root.unmount());
      acpmuxPerf.addLayout = addLayout;
      acpmuxPerf.enabled = false;
    }
  });
});
