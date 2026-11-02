import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";

// The rail sits beside the transcript's text column, which narrows when Interface Scale or Agent
// Chat Zoom grows the page zoom. A scale change must place the rail again, not only a width change.

const scope = globalThis as Record<string, unknown>;
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

test("an Interface Scale change places the rail again", async () => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  dom.window.document.documentElement.style.setProperty("--cmux-ui-scale", "1");
  // Imported after the DOM is in place: the scale store listens on `window` when it loads.
  const { useRailPlacement } = await import("./useRailPlacement");

  const placements: number[] = [];
  function Probe() {
    const scroller = useRef<HTMLDivElement>(null);
    const placement = useRailPlacement(scroller, 1000, 1000);
    placements.push(placement.gutter);
    return (
      <div className="acpmux-shell">
        <div ref={scroller} />
      </div>
    );
  }
  await act(async () => {
    root = createRoot(dom!.window.document.getElementById("root")!);
    root.render(<Probe />);
  });
  // Standard column at scale 1 on a 1000px pane: 800px wide (#31510), so the text starts 100px in.
  expect(placements.at(-1)).toBe(100);

  await act(async () => {
    dom!.window.document.documentElement.style.setProperty("--cmux-ui-scale", "2");
    dom!.window.dispatchEvent(new dom!.window.Event("cmux-ui-scale-change"));
  });
  // At scale 2 the column is 400 CSS px, so the text starts 300px in.
  expect(placements.at(-1)).toBe(300);
});
