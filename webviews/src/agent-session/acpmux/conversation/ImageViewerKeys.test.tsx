// u2647 follow-up: the image viewer's icon buttons name the key that presses them, to VoiceOver
// (aria-keyshortcuts) and in the tooltip, as every dialog button does: Close ⎋, Previous ←, Next →.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { anchoredHandoffScale, ImageViewer } from "./ImageViewer";

// Base UI's focus code schedules frames that may run after a test: the frame functions stay installed.
installFrames();

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

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

function render(node: React.ReactNode): Document {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
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
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(node));
  return dom.window.document;
}

function button(document: Document, label: string): HTMLButtonElement {
  const found = Array.from(document.querySelectorAll("button")).find((b) => b.getAttribute("aria-label") === label);
  if (!found) throw new Error(`no button labeled ${label}`);
  return found;
}

test("the image viewer's Close, Previous and Next name their keys", () => {
  const images = [
    { src: "a.png", alt: "A" },
    { src: "b.png", alt: "B" },
  ];
  const document = render(<ImageViewer images={images} index={0} onIndex={() => {}} onClose={() => {}} />);
  const labels = Array.from(document.querySelectorAll("button[aria-label]")).map((b) => b.getAttribute("aria-label")!);
  const close = button(
    document,
    labels.find((l) => /close/i.test(l))!,
  );
  const previous = button(
    document,
    labels.find((l) => /previous/i.test(l))!,
  );
  const next = button(
    document,
    labels.find((l) => /next/i.test(l))!,
  );
  for (const [element, aria, glyph] of [
    [close, "Escape", "⎋"],
    [previous, "ArrowLeft", "←"],
    [next, "ArrowRight", "→"],
  ] as const) {
    expect(element.getAttribute("aria-keyshortcuts")).toBe(aria);
    expect(element.getAttribute("title")).toBe(`${element.getAttribute("aria-label")} ${glyph}`);
  }
});

test("anchored handoff fits the source inside the viewer image", () => {
  expect(
    anchoredHandoffScale({ left: 10, top: 20, width: 100, height: 60 }, { left: 0, top: 0, width: 800, height: 600 }),
  ).toBeCloseTo(0.1);
  expect(
    anchoredHandoffScale({ left: 0, top: 0, width: 0, height: 0 }, { left: 0, top: 0, width: 10, height: 10 }),
  ).toBe(1);
});
