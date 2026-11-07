// A page for the fold tests that run on Session Info's fold (session-info/foldMotion.ts): JSDOM with Web
// Animations recorded (finished by the test), a laid-out height for every box (JSDOM lays out nothing:
// a box is 20px per element it draws, and nothing inside a closed <details> past its summary), and the page's motion switch. See fold-settle-*.test.tsx.
import { afterEach, beforeEach, expect } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { MOTION_SETTLE, MOTION_SETTLE_MS } from "../src/motion/scale.generated";

export type Animated = {
  target: HTMLElement;
  keyframes: Keyframe[];
  options: KeyframeAnimationOptions;
  /// Ends it as the browser does: onfinish, then React commits what it set.
  finish: () => void;
};

export const fold = {
  container: undefined as unknown as HTMLElement,
  animations: [] as Animated[],
};

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
  "Event",
  "MouseEvent",
  "KeyboardEvent",
  "localStorage",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

/// Installs the page before each test of the calling file and tears it down after.
export function useFoldPage() {
  beforeEach(() => {
    dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
    for (const key of GLOBALS) saved.set(key, scope[key]);
    Object.assign(scope, {
      window: dom.window,
      document: dom.window.document,
      navigator: dom.window.navigator,
      Node: dom.window.Node,
      HTMLElement: dom.window.HTMLElement,
      Element: dom.window.Element,
      Event: dom.window.Event,
      MouseEvent: dom.window.MouseEvent,
      KeyboardEvent: dom.window.KeyboardEvent,
      localStorage: dom.window.localStorage,
      getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
      IS_REACT_ACT_ENVIRONMENT: true,
    });
    const proto = dom.window.HTMLElement.prototype as unknown as Record<string, unknown>;
    Object.defineProperty(proto, "offsetHeight", {
      configurable: true,
      get(this: HTMLElement) {
        // A closed <details> draws only its summary.
        if (this.closest("details:not([open]) > :not(summary)")) return 0;
        return this.querySelectorAll("*").length * 20 + (this.textContent ? 20 : 0);
      },
    });
    fold.animations = [];
    proto.animate = function (this: HTMLElement, keyframes: Keyframe[], options: KeyframeAnimationOptions) {
      const animation = {
        onfinish: null as null | (() => void),
        oncancel: null as null | (() => void),
        cancel() {
          animation.oncancel?.();
        },
      };
      fold.animations.push({
        target: this,
        keyframes,
        options,
        finish: () => act(() => animation.onfinish?.()),
      });
      return animation;
    };
    fold.container = dom.window.document.getElementById("root")!;
  });

  afterEach(async () => {
    if (root) await act(async () => root!.unmount());
    root = undefined;
    dom?.window.close();
    dom = undefined;
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
    saved.clear();
  });
}

export function render(node: ReactNode) {
  act(() => {
    root ??= createRoot(fold.container);
    root.render(node);
  });
}

export const click = (target: Element) => act(() => (target as HTMLElement).click());

/// Reduce Motion, as the WebTheme bootstrap marks it on the root.
export function reduceMotion() {
  document.documentElement.dataset.cmuxMotion = "reduced";
}

/// A fold animation that rides the settle: its height moves over the settle's duration and curve.
export function expectSettle(animation: Animated | undefined) {
  expect(animation).toBeDefined();
  expect(animation!.options.duration).toBe(MOTION_SETTLE_MS);
  expect(animation!.options.easing).toBe(MOTION_SETTLE);
  expect(animation!.keyframes.every((frame) => "height" in frame)).toBe(true);
}
