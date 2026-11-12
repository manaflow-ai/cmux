// The split edge's contract (SplitEdge.tsx): a line between two panes drags like a split divider. A drag
// writes the pane's width to its property (on the pane or its parent) within bounds, once a frame; the
// release saves it and a later mount restores it before paint; a double-click puts the default back.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SplitEdge, splitEdgeWidth } from "./SplitEdge";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "PointerEvent",
  "getComputedStyle",
  "localStorage",
  "innerWidth",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "matchMedia",
  "IS_REACT_ACT_ENVIRONMENT",
];

function render(node: React.ReactNode): Document {
  dom ??= new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const win = dom.window;
  if (saved.size === 0) for (const key of KEYS) saved.set(key, scope[key]);
  // Frames run when the test flushes them, so a drag's coalescing is visible.
  frames = [];
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    PointerEvent: win.MouseEvent,
    getComputedStyle: win.getComputedStyle,
    localStorage: win.localStorage,
    innerWidth: 1000,
    requestAnimationFrame: (run: () => void) => frames.push(run),
    cancelAnimationFrame: (id: number) => {
      if (id > 0) frames[id - 1] = () => undefined;
    },
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root ??= createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}
let frames: (() => void)[] = [];
const flushFrames = () => {
  const due = frames;
  frames = [];
  for (const run of due) run();
};

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.localStorage.clear();
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

/** Gives `element` the box a 1000px-wide page lays out: the pane from x = `left` to `right`. */
const place = (element: Element, left: number, right: number) => {
  element.getBoundingClientRect = () =>
    ({ left, right, width: right - left, top: 0, bottom: 600, height: 600, x: left, y: 0 }) as DOMRect;
};
const pointer = (target: Element, type: string, clientX: number) =>
  act(() => {
    target.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientX }));
  });

test("the width a drag gives stays within bounds, in px or as a share of the page", () => {
  expect(splitEdgeWidth("left", 400, { left: 600, right: 1000 }, "px", 1000, 240, 480)).toBe(480);
  expect(splitEdgeWidth("left", 700, { left: 600, right: 1000 }, "px", 1000, 240, 480)).toBe(300);
  expect(splitEdgeWidth("right", 250, { left: 0, right: 200 }, "px", 1000, 160, 400)).toBe(250);
  expect(splitEdgeWidth("left", 400, { left: 600, right: 1000 }, "vw", 1000, 20, 80)).toBe(60);
  expect(splitEdgeWidth("left", 0, { left: 600, right: 1000 }, "vw", 1000, 20, 80)).toBe(80);
});

test("dragging the edge sets the pane's width once a frame, and the release saves it", () => {
  const doc = render(
    <div className="pane">
      <SplitEdge side="right" property="--list-width" storageKey="test.list" min={160} max={400} />
    </div>,
  );
  const pane = doc.querySelector<HTMLElement>(".pane")!;
  const edge = doc.querySelector(".ui-split-edge")!;
  place(pane, 0, 200);
  // A press that never moves changes nothing.
  pointer(edge, "pointerdown", 200);
  pointer(edge, "pointerup", 200);
  expect(pane.style.getPropertyValue("--list-width")).toBe("");
  expect(localStorage.getItem("test.list")).toBeNull();
  pointer(edge, "pointerdown", 200);
  expect(pane.dataset.splitResizing).toBe("");
  expect(doc.documentElement.dataset.splitResizing).toBe("");
  pointer(edge, "pointermove", 260);
  pointer(edge, "pointermove", 300);
  expect(pane.style.getPropertyValue("--list-width")).toBe("");
  expect(frames.length).toBe(1);
  flushFrames();
  expect(pane.style.getPropertyValue("--list-width")).toBe("300px");
  pointer(edge, "pointermove", 900);
  pointer(edge, "pointerup", 900);
  expect(pane.style.getPropertyValue("--list-width")).toBe("400px");
  expect(pane.dataset.splitResizing).toBeUndefined();
  expect(doc.documentElement.dataset.splitResizing).toBeUndefined();
  expect(localStorage.getItem("test.list")).toBe("400");

  // A double-click forgets it: the pane's CSS default shows again.
  act(() => {
    edge.dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
  });
  expect(pane.style.getPropertyValue("--list-width")).toBe("");
  expect(localStorage.getItem("test.list")).toBeNull();
});

test("a saved width is on the parent before the first paint, and leaves with the edge", () => {
  render(<div />);
  localStorage.setItem("test.share", "35");
  const doc = render(
    <section className="shell">
      <aside>
        <SplitEdge side="left" property="--share" storageKey="test.share" unit="vw" min={20} max={80} on="parent" />
      </aside>
    </section>,
  );
  const shell = doc.querySelector<HTMLElement>(".shell")!;
  expect(shell.style.getPropertyValue("--share")).toBe("35vw");
  render(
    <section className="shell">
      <aside />
    </section>,
  );
  expect(shell.style.getPropertyValue("--share")).toBe("");
});

test("an edge that leaves mid-drag gives the page its cursor and frames back", () => {
  const doc = render(
    <div className="pane">
      <SplitEdge side="right" property="--list-width" storageKey="test.gone" min={160} max={400} />
    </div>,
  );
  const edge = doc.querySelector(".ui-split-edge")!;
  place(doc.querySelector(".pane")!, 0, 200);
  pointer(edge, "pointerdown", 200);
  pointer(edge, "pointermove", 260);
  expect(doc.documentElement.dataset.splitResizing).toBe("");
  render(<div className="pane" />);
  expect(doc.documentElement.dataset.splitResizing).toBeUndefined();
  expect(localStorage.getItem("test.gone")).toBeNull();
});
