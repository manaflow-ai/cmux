// l10n-allow-file: test fixture addresses, not shipped UI.
// A turn's preview card shows a loopback page as a scaled thumbnail that takes no input and opens
// a tab when clicked. A component gallery stage (`/gallery/frame.html?entry=<id>`) is the
// exception: after Load preview it draws at its own size and takes input, so the reader can use
// the component in the chat.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { PreviewCard } from "./PreviewCard";
import { layoutConversation } from "../model";
import { GALLERY_FRAME_HEIGHT, isGalleryFrame, PREVIEW_FRAME_HEIGHT, previewFrameHeight } from "./previewUrl";

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

test("only the gallery's own mounts on loopback are live stages", () => {
  // The address comes from reply text, so any page ending in frame.html must not take input.
  expect(isGalleryFrame("http://localhost:4210/latest/frame.html?entry=x")).toBe(true);
  expect(isGalleryFrame("http://localhost:4210/wt/my-branch/frame.html?entry=x")).toBe(true);
  expect(isGalleryFrame("http://0.0.0.0:4200/gallery/frame.html?entry=x")).toBe(true);
  expect(isGalleryFrame("http://localhost:3000/frame.html?entry=x")).toBe(false);
  expect(isGalleryFrame("http://localhost:3000/admin/frame.html?entry=x")).toBe(false);
  expect(isGalleryFrame("http://localhost:3000/gallery/admin/frame.html?entry=x")).toBe(false);
  expect(isGalleryFrame("http://localhost:3000/wt/a/b/frame.html?entry=x")).toBe(false);
  expect(isGalleryFrame("http://localhost:3000/x/gallery/frame.html?entry=x")).toBe(false);
  expect(isGalleryFrame("https://example.com/gallery/frame.html?entry=x")).toBe(false);
  expect(isGalleryFrame("http://localhost.example.com/gallery/frame.html?entry=x")).toBe(false);
});

test("loading a gallery stage does not move the transcript: placeholder, frame and estimate agree", () => {
  const stage = "http://127.0.0.1:5173/gallery/frame.html?entry=agent-pane.preview-card";
  const page = "http://127.0.0.1:3000/admin";
  expect(previewFrameHeight(stage)).toBe(GALLERY_FRAME_HEIGHT);
  expect(previewFrameHeight(page)).toBe(PREVIEW_FRAME_HEIGHT);
  const dir = path.join(import.meta.dir, "..");
  const styles = readFileSync(path.join(dir, "styles.css"), "utf8");
  const conversation = readFileSync(path.join(dir, "conversation/conversation.css"), "utf8");
  expect(styles).toContain(`.acpmux-turn-preview-frame--live{height:${GALLERY_FRAME_HEIGHT}px;`);
  expect(styles).toContain(`.acpmux-turn-preview-frame{position:relative;height:${PREVIEW_FRAME_HEIGHT}px;`);
  expect(conversation).toMatch(
    new RegExp(`\\.acpmux-turn-preview-unloaded--live \\{\\s*height: ${GALLERY_FRAME_HEIGHT}px;`),
  );
  expect(conversation).toMatch(new RegExp(`\\.acpmux-turn-preview-unloaded \\{[^}]*height: ${PREVIEW_FRAME_HEIGHT}px;`));
  // The placeholder takes the live height before the click.
  root = createRoot(container);
  act(() => root!.render(<PreviewCard url={stage} onOpen={() => {}} />));
  expect(container.querySelector(".acpmux-turn-preview-unloaded")!.classList.contains("acpmux-turn-preview-unloaded--live")).toBe(true);
  // The virtualizer's estimate: the 58px head, the frame, and 14px below (model.ts).
  const heights = layoutConversation(
    [
      { id: "preview-a", kind: "preview", text: stage },
      { id: "preview-b", kind: "preview", text: page },
    ] as never,
    600,
  ).heights;
  expect([...heights]).toEqual([58 + GALLERY_FRAME_HEIGHT + 14, 58 + PREVIEW_FRAME_HEIGHT + 14]);
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
