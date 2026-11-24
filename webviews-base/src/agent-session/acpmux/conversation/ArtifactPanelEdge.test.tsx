// The side panel a table opens in sits beside the chat with a line between them, and that line drags
// as a split divider does (Leo, 2026-11-09: "it opened up on the right split, but then it's like there's
// this supposed divider-looking thing that I can't actually drag, and it just looks super awkward").
import { afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ArtifactPanel } from "./ArtifactPanel";

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
  // The page reads its width from the window, which JSDOM sizes at 1024.
  Object.defineProperty(win, "innerWidth", { configurable: true, value: 1000 });
  root ??= createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}
let frames: (() => void)[] = [];

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.localStorage.clear();
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
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

test("the side panel a table opens in drags from its left edge, sizing everything beside the chat", () => {
  const doc = render(
    <section className="acpmux-shell">
      <ArtifactPanel
        artifact={{ kind: "markdown", lang: "markdown", code: "| Failure | Retried |\n| --- | --- |\n| 5xx | yes |" }}
        onClose={() => undefined}
      />
    </section>,
  );
  const shell = doc.querySelector<HTMLElement>(".acpmux-shell")!;
  const panel = doc.querySelector<HTMLElement>(".acpmux-artifact")!;
  const edge = panel.querySelector(":scope > .ui-split-edge");
  expect(edge).not.toBeNull();
  expect(edge!.getAttribute("data-side")).toBe("left");
  place(panel, 540, 1000);
  pointer(edge!, "pointerdown", 540);
  pointer(edge!, "pointermove", 400);
  pointer(edge!, "pointerup", 400);
  // On the shell, where the Background tasks column and the header's push read the width too.
  expect(shell.style.getPropertyValue("--acpmux-artifact-share")).toBe("60vw");
  expect(localStorage.getItem("cmux.agentPane.artifact.share")).toBe("60");
});
