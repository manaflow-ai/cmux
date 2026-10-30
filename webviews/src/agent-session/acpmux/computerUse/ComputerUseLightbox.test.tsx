// Leo 2026-10-29, on the live computer use card: "why can't I click and drag? And why can't I full
// screen this picture?". The card's Full Screen button opens the app over the whole pane on the frame
// the card already shows (no blank first paint), live: a static Live badge, and each new frame the
// host pushes replaces it. It zooms (+ - 0, Command-scroll) and pans with a drag, Open in Agent
// Activity asks the host, and Escape or Close ends it.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ComputerUsePreviewCard } from "./ComputerUsePreviewCard";
import type { ComputerUsePreview } from "./computerUsePreview";

// Base UI's focus code schedules frames that may run after a test: the frame functions stay installed.
const globals = globalThis as Record<string, unknown>;
globals.requestAnimationFrame ??= (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0);
globals.cancelAnimationFrame ??= (id: number) => clearTimeout(id);

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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

const frame = (n: number) => `data:image/jpeg;base64,frame${n}`;
const running: ComputerUsePreview = {
  session: "cua_t1",
  app: "Microsoft Edge",
  done: false,
  frame: frame(1),
  pointer: { x: 0.5, y: 0.25, click: 1, windowWidth: 1280 },
};

/** The card under a host that pushes `preview`; `push` sends the next one. */
function render() {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of GLOBALS) saved.set(key, scope[key]);
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
  const opened: string[] = [];
  let push: (next: ComputerUsePreview | null) => void = () => undefined;
  function Host() {
    const [preview, setPreview] = useState<ComputerUsePreview | null>(running);
    push = setPreview;
    return <ComputerUsePreviewCard preview={preview} onOpen={(id) => opened.push(id)} onClose={() => undefined} />;
  }
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(<Host />));
  const document = dom.window.document;
  return {
    document,
    opened,
    push: (next: ComputerUsePreview | null) => act(() => push(next)),
    click: (selector: string) => act(() => document.querySelector<HTMLElement>(selector)!.click()),
    key: (key: string) =>
      act(() => {
        document
          .querySelector(".acpmux-cu-viewer")!
          .dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
      }),
    viewer: () => document.querySelector<HTMLElement>(".acpmux-cu-viewer"),
    image: () => document.querySelector<HTMLImageElement>(".acpmux-cu-viewer__frame img"),
    box: () => document.querySelector<HTMLElement>(".acpmux-cu-viewer__frame")!,
  };
}

test("Full Screen opens the app over the pane on the frame the card shows, with a static Live badge", () => {
  const page = render();
  expect(page.viewer()).toBeNull();
  const button = page.document.querySelector('.acpmux-cu-preview button[aria-label="Full Screen"]');
  expect(button).not.toBeNull();
  page.click('.acpmux-cu-preview button[aria-label="Full Screen"]');
  expect(page.viewer()).not.toBeNull();
  // The first paint is the frame the card already had: no blank and no loading state.
  expect(page.image()?.getAttribute("src")).toBe(frame(1));
  expect(page.document.querySelector(".acpmux-image-viewer-title")?.textContent).toBe("Microsoft Edge");
  const badge = page.document.querySelector(".acpmux-cu-viewer__state");
  expect(badge?.textContent).toBe("Live");
  expect(badge?.hasAttribute("data-live")).toBe(true);
});

test("it follows the newest frame the host pushes, and says Done when the session ends", () => {
  const page = render();
  page.click('.acpmux-cu-preview button[aria-label="Full Screen"]');
  page.push({ ...running, frame: frame(2) });
  expect(page.image()?.getAttribute("src")).toBe(frame(2));
  page.push({ ...running, frame: frame(3), done: true, pointer: undefined });
  expect(page.image()?.getAttribute("src")).toBe(frame(3));
  expect(page.document.querySelector(".acpmux-cu-viewer__state")?.textContent).toBe("Done");
  // The host hides the done card: the full screen view stays on the last frame until closed.
  page.push(null);
  expect(page.viewer()).not.toBeNull();
  expect(page.image()?.getAttribute("src")).toBe(frame(3));
});

test("the frame box takes the frame's shape once it loads, and the cursor shows on it", () => {
  const page = render();
  page.click('.acpmux-cu-preview button[aria-label="Full Screen"]');
  const image = page.image()!;
  Object.defineProperty(image, "naturalWidth", { value: 1600 });
  Object.defineProperty(image, "naturalHeight", { value: 1000 });
  act(() => {
    image.dispatchEvent(new dom!.window.Event("load"));
  });
  expect(page.box().hasAttribute("data-fitted")).toBe(true);
  expect(page.box().style.getPropertyValue("--cu-frame-ratio")).toBe("1.6");
  expect(page.box().style.getPropertyValue("--cu-pointer-x")).toBe("0.5");
  expect(page.box().querySelector(".acpmux-cu-preview__arrow")).not.toBeNull();
});

test("+ and - zoom, 0 fits, and a drag pans the zoomed frame", () => {
  const page = render();
  page.click('.acpmux-cu-preview button[aria-label="Full Screen"]');
  const transform = () => page.box().style.transform;
  expect(transform()).toBe("translate(0px, 0px) scale(1)");
  page.key("+");
  expect(transform()).toBe("translate(0px, 0px) scale(2)");
  const stage = page.document.querySelector<HTMLElement>(".acpmux-cu-viewer__stage")!;
  expect(stage.classList.contains("is-zoomed")).toBe(true);
  (stage as unknown as { setPointerCapture(): void }).setPointerCapture = () => undefined;
  const pointer = (type: string, x: number, y: number) =>
    act(() => {
      stage.dispatchEvent(new dom!.window.MouseEvent(type, { bubbles: true, clientX: x, clientY: y, button: 0 }));
    });
  pointer("pointerdown", 0, 0);
  pointer("pointermove", 12, -8);
  pointer("pointerup", 12, -8);
  expect(transform()).toBe("translate(12px, -8px) scale(2)");
  // A new frame keeps the zoom: the person keeps looking at the same spot.
  page.push({ ...running, frame: frame(2) });
  expect(transform()).toBe("translate(12px, -8px) scale(2)");
  page.key("0");
  expect(transform()).toBe("translate(0px, 0px) scale(1)");
});

test("Open in Agent Activity asks the host for the session; Close ends the view", () => {
  const page = render();
  page.click('.acpmux-cu-preview button[aria-label="Full Screen"]');
  page.click('.acpmux-cu-viewer button[aria-label="Open in Agent Activity"]');
  expect(page.opened).toEqual(["cua_t1"]);
  page.click('.acpmux-cu-viewer button[aria-label="Close"]');
  expect(page.viewer()).toBeNull();
  // The card is still there.
  expect(page.document.querySelector(".acpmux-cu-preview")).not.toBeNull();
});
