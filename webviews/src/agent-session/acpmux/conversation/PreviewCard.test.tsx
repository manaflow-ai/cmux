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
import {
  GALLERY_FRAME_HEIGHT,
  isGalleryFrame,
  PREVIEW_COMPACT_HEIGHT,
  PREVIEW_FRAME_HEIGHT,
  PREVIEW_HEAD_HEIGHT,
  previewCardHeight,
  previewFrameHeight,
} from "./previewUrl";

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
  // React's scheduler may still run a passive effect; let its queued task run while the window is there.
  await new Promise((resolve) => setTimeout(resolve, 0));
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

const STAGE = "http://127.0.0.1:5173/gallery/frame.html?entry=agent-pane.preview-card";
const PAGE = "http://127.0.0.1:3000/admin";

// Leo, 2026-10-15 (#20931): a loopback address a turn merely mentioned drew the whole card, a 58px
// head over a 180px (a gallery stage: 360px) empty box around one "Load preview" button. Until the
// reader clicks Load preview, the card is one compact row, like Claude desktop's link chips.
test("an unloaded card is one compact row, with Load preview among its actions and no empty box", () => {
  for (const url of [PAGE, STAGE]) {
    root = createRoot(container);
    act(() => root!.render(<PreviewCard url={url} onOpen={() => {}} />));
    const card = container.querySelector(".acpmux-turn-preview")!;
    expect(card.hasAttribute("data-compact")).toBe(true);
    expect([...card.children].map((child) => child.className)).toEqual(["acpmux-turn-preview-head"]);
    expect(container.querySelector(".acpmux-turn-preview-frame")).toBeNull();
    expect(container.querySelector("iframe")).toBeNull();
    const load = container.querySelector(".acpmux-turn-preview-head .acpmux-turn-preview-load");
    // Not its English text: another suite in the same run may stub the catalog.
    expect(load).not.toBeNull();
    act(() => root!.unmount());
    root = undefined;
  }
  const conversation = readFileSync(path.join(import.meta.dir, "conversation.css"), "utf8");
  expect(conversation).not.toContain(".acpmux-turn-preview-unloaded");
  expect(conversation).toMatch(
    new RegExp(
      `\\.acpmux-turn-preview\\[data-compact\\] \\.acpmux-turn-preview-head \\{[^}]*min-height: ${PREVIEW_COMPACT_HEIGHT}px;`,
    ),
  );
});

// Leo, ask-2d3083506c ("did we fix this bullshit yet"): a card for
// `127.0.0.1:47811?token=ad27…` printed the whole token in its head. The head, its labels and its
// title read a secret-looking query value as •••; only the link itself keeps the real address.
test("the head never shows a secret query value, whatever the secret's name", () => {
  const value = "fixture-dev-server-token-47811";
  for (const name of ["token", "key", "secret", "auth", "sig", "password", "code", "api_key", "access_token"]) {
    const url = `http://127.0.0.1:47811/?${name}=${value}&tab=1`;
    root = createRoot(container);
    act(() => root!.render(<PreviewCard url={url} onOpen={() => {}} />));
    const head = container.querySelector(".acpmux-turn-preview-head")!;
    expect(head.textContent).not.toContain(value);
    expect(head.textContent).toContain(`${name}=•••&tab=1`);
    for (const element of [head, ...head.querySelectorAll("*")]) {
      for (const attribute of element.getAttributeNames()) {
        if (attribute === "href") continue;
        expect(element.getAttribute(attribute)).not.toContain(value);
      }
    }
    expect(container.querySelector(".acpmux-turn-preview-address")!.getAttribute("href")).toBe(url);
    act(() => root!.unmount());
    root = undefined;
  }
});

// Leo, ask-2d3083506c: the head's "Open in tab" and "Open in" were outlined pills. They read like
// the link hover card's actions and like Load preview beside them: no outline, muted text, and a
// background only under the pointer.
test("the head's Open in tab and Open in are quiet: no outline, a background only on hover", () => {
  root = createRoot(container);
  act(() => root!.render(<PreviewCard url={PAGE} onOpen={() => {}} />));
  expect(container.querySelectorAll(".acpmux-turn-preview-head .acpmux-review-changes")).toHaveLength(2);
  const conversation = readFileSync(path.join(import.meta.dir, "conversation.css"), "utf8");
  const rule = (selector: string) =>
    new RegExp(`(?:^|\\n)${selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} \\{([^}]*)\\}`).exec(conversation)?.[1];
  const rest = rule(".acpmux-turn-preview-head .acpmux-review-changes");
  expect(rest).toBeDefined();
  expect(rest).toContain("box-shadow: none;");
  expect(rest).toContain("color: var(--agent-muted);");
  expect(rest).not.toContain("background");
  expect(rest).not.toMatch(/border:\s*[^0n]/);
  const hover = rule(".acpmux-turn-preview-head .acpmux-review-changes:hover");
  expect(hover).toContain("background: color-mix(in srgb, var(--agent-text) 6%, transparent);");
  expect(hover).toContain("color: var(--agent-text);");
});

test("a loaded card keeps its head and frame: 180px for a page, 360px for a gallery stage", () => {
  expect(previewFrameHeight(STAGE)).toBe(GALLERY_FRAME_HEIGHT);
  expect(previewFrameHeight(PAGE)).toBe(PREVIEW_FRAME_HEIGHT);
  expect(PREVIEW_FRAME_HEIGHT).toBe(180);
  expect(GALLERY_FRAME_HEIGHT).toBe(360);
  const styles = readFileSync(path.join(import.meta.dir, "..", "styles.css"), "utf8");
  expect(styles).toContain(`.acpmux-turn-preview-frame--live{height:${GALLERY_FRAME_HEIGHT}px;`);
  expect(styles).toContain(`.acpmux-turn-preview-frame{position:relative;height:${PREVIEW_FRAME_HEIGHT}px;`);
  expect(styles).toContain(
    `.acpmux-turn-preview-head{display:flex;align-items:center;gap:11px;min-height:${PREVIEW_HEAD_HEIGHT}px;`,
  );
  for (const url of [PAGE, STAGE]) {
    const frame = render(url, []);
    expect(frame).not.toBeNull();
    const card = container.querySelector(".acpmux-turn-preview")!;
    expect(card.hasAttribute("data-compact")).toBe(false);
    expect(container.querySelector(".acpmux-turn-preview-load")).toBeNull();
    act(() => root!.unmount());
    root = undefined;
  }
  // The card's height once loaded: the head, the frame, and 14px below.
  expect(previewCardHeight(PAGE, true)).toBe(PREVIEW_HEAD_HEIGHT + 180 + 14);
  expect(previewCardHeight(STAGE, true)).toBe(PREVIEW_HEAD_HEIGHT + 360 + 14);
  expect(previewCardHeight(PAGE, false)).toBe(PREVIEW_COMPACT_HEIGHT + 14);
  expect(previewCardHeight(STAGE, false)).toBe(PREVIEW_COMPACT_HEIGHT + 14);
});

test("the transcript estimates a preview row at the compact row, page or gallery stage", () => {
  // measuredRowHeight sends a preview row to fallbackRowHeight (model.ts); a card mounts unloaded,
  // so the estimate is the compact row, and the ResizeObserver measures a card once it is loaded.
  const heights = layoutConversation(
    [
      { id: "preview-a", kind: "preview", text: STAGE },
      { id: "preview-b", kind: "preview", text: PAGE },
      { id: "preview-c", kind: "preview" },
    ] as never,
    600,
  ).heights;
  expect([...heights]).toEqual([PREVIEW_COMPACT_HEIGHT + 14, PREVIEW_COMPACT_HEIGHT + 14, PREVIEW_COMPACT_HEIGHT + 14]);
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
