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
    return new dom.window.DOMRect(0, 0, 100, 20);
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
