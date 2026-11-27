// The beside-the-stack mask reads the dock's layout once per frame, never in the microtask after a
// commit that changed the dock: a MutationObserver's callback runs right after the commit's writes, so
// a read there forced the page's style and layout ("style forced by script: observer" in the replay
// trace, visible-frame-p95-under-load). A resize still reads at once: a ResizeObserver's callback comes
// after the frame's layout, when reads cost none.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useRef, type RefObject } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import { importWithDom } from "../../../../test/support/importWithDom";

// Loaded with a document in place: this file installs its own jsdom per test (import-order-lint).
const { useBesideStack } = await importWithDom(() => import("./useBesideStack"));

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let reads = 0;
let frames: FrameRequestCallback[] = [];
let resized: (() => void)[] = [];

const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "Element",
  "HTMLElement",
  "MutationObserver",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const view = dom.window;
  for (const key of GLOBALS) saved.set(key, scope[key]);
  reads = 0;
  frames = [];
  resized = [];
  class Sizes {
    constructor(private readonly callback: () => void) {
      resized.push(() => this.callback());
    }
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  Object.assign(scope, {
    window: view,
    document: view.document,
    navigator: view.navigator,
    Node: view.Node,
    Element: view.Element,
    HTMLElement: view.HTMLElement,
    MutationObserver: view.MutationObserver,
    ResizeObserver: Sizes,
    requestAnimationFrame: (callback: FrameRequestCallback) => frames.push(callback),
    cancelAnimationFrame: () => {},
    getComputedStyle: view.getComputedStyle.bind(view),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  view.Element.prototype.getBoundingClientRect = function () {
    reads += 1;
    return { x: 0, y: 0, top: 0, left: 0, right: 400, bottom: 300, width: 400, height: 300 } as DOMRect;
  };
  root = createRoot(view.document.getElementById("root")!);
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

function Pane({ dock }: { dock: HTMLElement }) {
  const scroller = useRef<HTMLElement | null>(null);
  scroller.current = dock.parentElement;
  useBesideStack(dock, scroller as RefObject<HTMLElement | null>, "ghost");
  return null;
}

function mount() {
  const document = dom!.window.document;
  const view = document.createElement("div");
  const dock = document.createElement("div");
  const tray = document.createElement("div");
  tray.className = "acpmux-running-tray";
  const card = document.createElement("div");
  card.className = "acpmux-composer-box";
  dock.append(tray, card);
  view.append(dock);
  document.body.append(view);
  act(() => root!.render(<Pane dock={dock} />));
  return { dock, tray };
}

const flushMicrotasks = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

function runFrame() {
  const due = frames;
  frames = [];
  for (const callback of due) callback(0);
}

test("a dock changed by several commits in one frame reads its layout once, in the frame, not after each commit", async () => {
  const { dock, tray } = mount();
  reads = 0;
  // Three commits in the frame: a tray's corners round (`data-card`), a ghost tray is removed, a notice comes.
  tray.setAttribute("data-card", "");
  await flushMicrotasks();
  const ghost = dom!.window.document.createElement("div");
  ghost.className = "acpmux-running-tray ghost";
  dock.append(ghost);
  await flushMicrotasks();
  ghost.remove();
  await flushMicrotasks();
  // No read after a commit's writes, in the observers' microtasks.
  expect(reads).toBe(0);
  runFrame();
  const once = reads;
  expect(once).toBeGreaterThan(0);
  // One read pass for the frame: nothing more is queued.
  runFrame();
  expect(reads).toBe(once);
});

test("a surface's motion ending reads on the next frame, not in its event", async () => {
  const { tray } = mount();
  reads = 0;
  tray.dispatchEvent(new dom!.window.Event("transitionend", { bubbles: true }));
  tray.dispatchEvent(new dom!.window.Event("animationend", { bubbles: true }));
  expect(reads).toBe(0);
  runFrame();
  expect(reads).toBeGreaterThan(0);
});

test("a resize still reads at once: its callback comes after the frame's layout", () => {
  mount();
  reads = 0;
  for (const callback of resized) callback();
  expect(reads).toBeGreaterThan(0);
});
