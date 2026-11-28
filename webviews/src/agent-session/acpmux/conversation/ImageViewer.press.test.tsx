// A pan of the zoomed image ends on its release, also one the page never hears (over another window,
// or after the window lost focus mid-pan): the window's own blur, or the first move with no button
// down. Before, a later move over the stage, with no button down, still panned the image.
import { afterAll, afterEach, expect, test } from "bun:test";
import { settleReact } from "../../../../test/support/domTeardown";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ImageViewer } from "./ImageViewer";

// Base UI's focus code schedules frames that may run after a test: the frame functions stay installed
// for the whole file, and go when it ends (the frames still pending then are cleared with them).
const frames = {
  requestAnimationFrame: globalThis.requestAnimationFrame,
  cancelAnimationFrame: globalThis.cancelAnimationFrame,
};
installFrames();
afterAll(async () => {
  const globals = globalThis as Record<string, unknown>;
  await settleReact();
  for (const [key, value] of Object.entries(frames)) {
    if (value === undefined) delete globals[key];
    else globals[key] = value;
  }
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installFrames() {
  const globals = globalThis as Record<string, unknown>;
  globals.requestAnimationFrame ??= (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0);
  globals.cancelAnimationFrame ??= (id: number) => clearTimeout(id);
}

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function render(node: React.ReactNode): Document {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(node));
  return dom.window.document;
}

for (const missed of ["the window's blur", "a move with no button down"] as const)
  test(`a pan released where the page never hears it ends on ${missed}: a later move does not pan`, () => {
    const document = render(
      <ImageViewer images={[{ src: "a.png", alt: "A" }]} index={0} onIndex={() => {}} onClose={() => {}} />,
    );
    const window = document.defaultView!;
    // jsdom has no pointer capture.
    window.HTMLElement.prototype.setPointerCapture = () => {};
    const stage = document.querySelector<HTMLElement>(".acpmux-image-viewer-stage")!;
    const image = () => document.querySelector<HTMLElement>(".acpmux-image-viewer-image")!.style.transform;
    act(() => void stage.dispatchEvent(new window.KeyboardEvent("keydown", { key: "+", bubbles: true })));
    expect(stage.classList.contains("is-zoomed")).toBe(true);
    const pointer = (type: string, clientX: number, buttons: number) =>
      act(
        () =>
          void stage.dispatchEvent(
            new window.MouseEvent(type, { bubbles: true, button: 0, clientX, clientY: 0, buttons }),
          ),
      );
    pointer("pointerdown", 0, 1);
    pointer("pointermove", 10, 1);
    const panned = image();
    expect(panned).toContain("translate(10px, 0px)");
    if (missed === "the window's blur") {
      act(() => void window.dispatchEvent(new window.FocusEvent("blur")));
      // A move with a button down: only the blur can have ended the pan.
      pointer("pointermove", 40, 1);
    } else pointer("pointermove", 40, 0);
    pointer("pointermove", 80, 1);
    expect(image()).toBe(panned);
  });
