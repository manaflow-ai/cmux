// New Tab list motion should measure on list changes, not on every unrelated render. Layout-only
// changes still arrive through ResizeObserver; this keeps the render path cheap without leaving a
// stale place when the cards grid changes columns.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement, useRef } from "react";
import { useListMotion } from "../src/agent-session/acpmux/newtab/listMotion";

const scope = globalThis as Record<string, unknown>;
const globalKeys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "ResizeObserver",
  "getComputedStyle",
  "matchMedia",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const savedGlobals = globalKeys.map((key) => [key, key in scope, scope[key]] as const);

let dom: JSDOM;
let host: HTMLElement;
let createRoot: typeof import("react-dom/client").createRoot;
let root: import("react-dom/client").Root;
let measureReads: WeakMap<Element, number>;
let animationCalls: number;
let originalRect: typeof HTMLElement.prototype.getBoundingClientRect;
let originalAnimate: typeof HTMLElement.prototype.animate;
let resizeCallbacks: (() => void)[] = [];

function Probe({ keys, tick }: { keys: readonly string[]; tick: number }) {
  const list = useRef<HTMLDivElement>(null);
  useListMotion(list, ".row", keys);
  return createElement(
    "div",
    { ref: list, "data-tick": tick },
    keys.map((key) => createElement("div", { className: "row", key }, key)),
  );
}

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  class TestResizeObserver {
    constructor(callback: () => void) {
      resizeCallbacks.push(callback);
    }
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  measureReads = new WeakMap();
  animationCalls = 0;
  originalRect = dom.window.HTMLElement.prototype.getBoundingClientRect;
  originalAnimate = dom.window.HTMLElement.prototype.animate;
  dom.window.HTMLElement.prototype.getBoundingClientRect = function () {
    measureReads.set(this, (measureReads.get(this) ?? 0) + 1);
    // A row sits one row height under the one before it, so a row arriving above it moves it.
    const index = this.classList.contains("row") ? [...this.parentElement!.children].indexOf(this) : 0;
    return new dom.window.DOMRect(0, index * 20, 100, 20);
  };
  dom.window.HTMLElement.prototype.animate = function () {
    animationCalls += 1;
    return { cancel() {} } as unknown as Animation;
  };
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    ResizeObserver: TestResizeObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    matchMedia: () => ({ matches: false }),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  Object.assign(dom.window, {
    ResizeObserver: TestResizeObserver,
    matchMedia: () => ({ matches: false }),
  });
  ({ createRoot } = await import("react-dom/client"));
  host = dom.window.document.getElementById("root")!;
});

beforeEach(() => {
  root = createRoot(host);
});

afterEach(() => {
  act(() => root.unmount());
  host.replaceChildren();
  dom.window.document.documentElement.dataset.agentMotion = "";
  measureReads = new WeakMap();
  animationCalls = 0;
  resizeCallbacks = [];
});

afterAll(() => {
  dom.window.HTMLElement.prototype.getBoundingClientRect = originalRect;
  dom.window.HTMLElement.prototype.animate = originalAnimate;
  dom.window.close();
  for (const [key, had, value] of savedGlobals) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("stable New Tab keys do not remeasure on unrelated renders", async () => {
  await act(async () => root.render(createElement(Probe, { keys: ["one", "two"], tick: 0 })));
  const list = host.firstElementChild!;
  const rows = [...list.children];
  const initialReads = [measureReads.get(list), ...rows.map((row) => measureReads.get(row))];

  // Callers commonly create a fresh keys array while updating another New Tab field. The value
  // signature is unchanged, so the layout effect should not repeat its synchronous DOM reads.
  await act(async () => root.render(createElement(Probe, { keys: ["one", "two"], tick: 1 })));
  expect([measureReads.get(list), ...rows.map((row) => measureReads.get(row))]).toEqual(initialReads);

  await act(async () => root.render(createElement(Probe, { keys: ["two", "one"], tick: 2 })));
  expect(measureReads.get(host.firstElementChild!)).toBeGreaterThan(initialReads[0]!);
});

test("explicit animation-off policy blocks Web Animations API rows", async () => {
  await act(async () => root.render(createElement(Probe, { keys: ["one"], tick: 0 })));
  const list = host.firstElementChild as HTMLElement;
  list.style.setProperty("--agent-motion-in", "10ms");
  document.documentElement.dataset.agentMotion = "off";

  await act(async () => root.render(createElement(Probe, { keys: ["two"], tick: 1 })));
  expect(animationCalls).toBe(0);
});

// A live window resize calls the list's ResizeObserver on every frame. Reading every row's place
// there forced a layout per frame (Leo 2026-10-20: the New Tab page's resize was "slow and wack");
// the places are read once, after the size holds still.
test("a live resize reads no row on its frames, then once when the size settles", async () => {
  await act(async () => root.render(createElement(Probe, { keys: ["one", "two"], tick: 0 })));
  const list = host.firstElementChild!;
  const rows = [...list.children];
  const reads = () => [measureReads.get(list) ?? 0, ...rows.map((row) => measureReads.get(row) ?? 0)];
  const before = reads();
  expect(resizeCallbacks.length).toBe(1);
  const tick = resizeCallbacks[0]!;
  tick(); // the observer's first call: the size the list mounted at
  for (let frame = 0; frame < 30; frame++) tick();
  expect(reads()).toEqual(before);

  // fixed-wait: waits out listMotion's 120 ms resize settle, the behavior under test.
  await new Promise((resolve) => setTimeout(resolve, 200));
  expect(reads()).toEqual(before.map((count) => count + 1));
});

// A row arriving resizes the list itself, and the observer reports that size after the effect read
// it. That is no resize: the next row arriving right after (two tabs closed in a row) still slides
// the rows under it. (The arriving row itself appears at once: no entry animations on the New Tab.)
test("the list's own size change from a row arriving leaves the next change animated", async () => {
  await act(async () => root.render(createElement(Probe, { keys: ["one"], tick: 0 })));
  const list = host.firstElementChild as HTMLElement;
  list.style.setProperty("--agent-motion-in", "10ms");
  list.style.setProperty("--agent-motion-move", "10ms");
  const tick = resizeCallbacks[0] as unknown as (entries: unknown[]) => void;
  const measured = [{ borderBoxSize: [{ inlineSize: 100, blockSize: 20 }] }];
  tick(measured); // the observer's first call: the size the list mounted at

  await act(async () => root.render(createElement(Probe, { keys: ["two", "one"], tick: 1 })));
  const first = animationCalls;
  expect(first).toBeGreaterThan(0);
  tick(measured); // the list's new height, as the effect just read it
  await act(async () => root.render(createElement(Probe, { keys: ["three", "two", "one"], tick: 2 })));
  expect(animationCalls).toBeGreaterThan(first);
});
