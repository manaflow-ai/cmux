// l10n-allow-file: test fixture addresses, not shipped UI.
// A turn's preview card shows a loopback page as a scaled thumbnail that takes no input and opens
// a tab when clicked. A component gallery stage (`/gallery/frame.html?entry=<id>`) is the
// exception: after Load preview it draws at its own size and takes input, so the reader can use
// the component in the chat.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PreviewCard } from "./PreviewCard";
import { isGalleryFrame } from "./previewUrl";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
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
  container = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  // React's scheduler may still run a passive effect; let it see the window before it goes.
  await new Promise((resolve) => setTimeout(resolve, 20));
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom?.window.close();
  dom = undefined;
});

function render(url: string, opened: string[]) {
  root = createRoot(container);
  act(() => root!.render(<PreviewCard url={url} onOpen={(next) => opened.push(next)} />));
  const load = container.querySelector<HTMLButtonElement>(".acpmux-turn-preview-load");
  expect(load).not.toBeNull();
  act(() => load!.click());
  return container.querySelector<HTMLElement>(".acpmux-turn-preview-frame")!;
}

test("a gallery stage is recognized by its frame path and entry", () => {
  expect(isGalleryFrame("http://127.0.0.1:5173/gallery/frame.html?entry=agent-pane.preview-card")).toBe(true);
  expect(isGalleryFrame("http://localhost:5173/live/frame.html?entry=x&theme=dark")).toBe(true);
  expect(isGalleryFrame("http://localhost:5173/gallery/frame.html")).toBe(false);
  expect(isGalleryFrame("http://localhost:5173/gallery/?entry=x")).toBe(false);
  expect(isGalleryFrame("http://localhost:3000/admin")).toBe(false);
  expect(isGalleryFrame("not a url")).toBe(false);
});

test("a gallery stage loads live: full size, focusable, and a click stays in the chat", () => {
  const opened: string[] = [];
  const frame = render("http://127.0.0.1:5173/gallery/frame.html?entry=agent-pane.preview-card", opened);
  expect(frame.classList.contains("acpmux-turn-preview-frame--live")).toBe(true);
  expect(frame.getAttribute("aria-hidden")).toBeNull();
  const iframe = frame.querySelector("iframe")!;
  expect(iframe.getAttribute("src")).toBe("http://127.0.0.1:5173/gallery/frame.html?entry=agent-pane.preview-card");
  expect(iframe.getAttribute("tabindex")).toBeNull();
  expect(iframe.getAttribute("sandbox")).toBe("allow-scripts allow-same-origin");
  act(() => frame.click());
  expect(opened).toEqual([]);
});

test("any other loopback page stays a thumbnail that opens a tab", () => {
  const opened: string[] = [];
  const frame = render("http://127.0.0.1:3000/admin?tab=1", opened);
  expect(frame.classList.contains("acpmux-turn-preview-frame--live")).toBe(false);
  expect(frame.getAttribute("aria-hidden")).toBe("true");
  expect(frame.querySelector("iframe")!.getAttribute("tabindex")).toBe("-1");
  act(() => frame.click());
  expect(opened).toEqual(["http://127.0.0.1:3000/admin?tab=1"]);
});
