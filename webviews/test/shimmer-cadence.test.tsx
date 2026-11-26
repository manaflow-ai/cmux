// l10n-allow-file: synthetic shimmer labels.
import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { RowShimmer, ShimmerEnabledContext, ShimmerText } from "../src/agent-session/acpmux/conversation/ShimmerText";
import { startShimmerCadence } from "../src/agent-session/acpmux/conversation/shimmerCadence";
import {
  configureThinkingLook,
  DEFAULT_THINKING_LOOK,
  resolveThinkingLook,
  THINKING_JUMP_BUTTON_KEY,
  THINKING_SHIMMER_BAND_KEY,
  THINKING_SHIMMER_KEY,
  THINKING_SHIMMER_PERIOD_KEY,
  thinkingLook,
} from "../src/agent-session/acpmux/conversation/thinkingLook";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM;
let root: Root | undefined;
let cleanup: (() => void) | undefined;
let intersect: (visible: boolean) => void;
let hidden = false;
let reduced = false;
let mediaChange: (() => void) | undefined;
let observerCount = 0;
const saved = new Map<string, unknown>();
const scope = globalThis as Record<string, unknown>;

beforeEach(() => {
  jest.useFakeTimers();
  hidden = reduced = false;
  observerCount = 0;
  dom = new JSDOM("<!doctype html><html><body><main></main></body></html>", { pretendToBeVisual: true });
  Object.defineProperty(dom.window.document, "hidden", { get: () => hidden });
  Object.defineProperty(dom.window, "matchMedia", {
    value: () => ({
      get matches() {
        return reduced;
      },
      addEventListener: (_: string, callback: () => void) => {
        mediaChange = callback;
      },
      removeEventListener: () => {
        mediaChange = undefined;
      },
    }),
  });
  Object.defineProperty(dom.window, "IntersectionObserver", {
    value: class {
      targets = new Set<Element>();
      constructor(callback: (entries: { target: Element; isIntersecting: boolean }[]) => void) {
        observerCount += 1;
        intersect = (visible) => callback(Array.from(this.targets, (target) => ({ target, isIntersecting: visible })));
      }
      observe(target: Element) {
        this.targets.add(target);
      }
      unobserve(target: Element) {
        this.targets.delete(target);
      }
      disconnect() {
        this.targets.clear();
      }
    },
  });
  const replacements = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  cleanup?.();
  cleanup = undefined;
  await settleReact();
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  jest.useRealTimers();
});

function label() {
  const element = document.createElement("span");
  document.body.append(element);
  cleanup = startShimmerCadence(element);
  return element;
}

const active = (element: Element) => element.classList.contains("is-shimmer-active");
const advance = (ms: number) => jest.advanceTimersByTime(ms);

test("visible labels wait 600 ms, sweep for 1000 ms, and restart every 4000 ms", () => {
  const element = label();
  advance(10000);
  expect(active(element)).toBe(false);
  intersect(true);
  advance(599);
  expect(active(element)).toBe(false);
  advance(1);
  expect(active(element)).toBe(true);
  for (let cycle = 0; cycle < 5; cycle += 1) {
    advance(999);
    expect(active(element)).toBe(true);
    advance(1);
    expect(active(element)).toBe(false);
    advance(2999);
    expect(active(element)).toBe(false);
    advance(1);
    expect(active(element)).toBe(true);
  }
});

test("hidden and offscreen labels cancel sweeps and resume after the initial delay", () => {
  const element = label();
  intersect(true);
  advance(600);
  hidden = true;
  document.dispatchEvent(new dom.window.Event("visibilitychange"));
  expect(active(element)).toBe(false);
  advance(10000);
  hidden = false;
  document.dispatchEvent(new dom.window.Event("visibilitychange"));
  advance(599);
  expect(active(element)).toBe(false);
  advance(1);
  expect(active(element)).toBe(true);
  intersect(false);
  expect(active(element)).toBe(false);
  advance(10000);
  intersect(true);
  advance(600);
  expect(active(element)).toBe(true);
  cleanup!();
  cleanup = undefined;
  advance(10000);
  expect(active(element)).toBe(false);
});

for (const [attribute, value] of [
  ["data-status-indicators", "static"],
  ["data-cmux-motion", "off"],
  ["data-cmux-motion", "reduced"],
  ["data-agent-motion", "off"],
  ["data-agent-motion", "reduced"],
  ["data-reduced-motion", "true"],
  ["data-cmux-page-hidden", ""],
] as const) {
  test(`${attribute}=${value} cancels timers and restarts with the full delay`, async () => {
    const element = label();
    intersect(true);
    advance(600);
    document.documentElement.setAttribute(attribute, value);
    await Promise.resolve();
    expect(active(element)).toBe(false);
    advance(10000);
    document.documentElement.removeAttribute(attribute);
    await Promise.resolve();
    advance(599);
    expect(active(element)).toBe(false);
    advance(1);
    expect(active(element)).toBe(true);
  });
}

test("system reduced motion cancels an initial delay and an active sweep", () => {
  const element = label();
  intersect(true);
  advance(300);
  reduced = true;
  mediaChange!();
  advance(10000);
  expect(active(element)).toBe(false);
  reduced = false;
  mediaChange!();
  advance(600);
  expect(active(element)).toBe(true);
  reduced = true;
  mediaChange!();
  expect(active(element)).toBe(false);
});

test("both React layers share visibility observation and nested groups can disable them", async () => {
  root = createRoot(document.querySelector("main")!);
  const render = (enabled: boolean) =>
    act(async () =>
      root!.render(
        <ShimmerEnabledContext value={enabled}>
          <ShimmerText text="Thinking" />
          <RowShimmer>Running command</RowShimmer>
        </ShimmerEnabledContext>,
      ),
    );
  await render(true);
  expect(observerCount).toBe(1);
  intersect(true);
  advance(600);
  expect(document.querySelectorAll(".is-shimmer-active")).toHaveLength(2);
  expect(document.querySelector(".cv-shimmer__band.is-shimmer-active")).not.toBeNull();
  expect(document.querySelector(".cv-row-shimmer.is-shimmer-active")).not.toBeNull();
  await render(false);
  advance(10000);
  expect(document.querySelectorAll(".is-shimmer-active")).toHaveLength(0);
  expect(document.querySelector(".cv-shimmer__base")?.textContent).toBe("Thinking");
  await render(true);
  intersect(true);
  advance(600);
  expect(document.querySelectorAll(".is-shimmer-active")).toHaveLength(2);
  const bands = Array.from(document.querySelectorAll(".is-shimmer-active"));
  await act(async () => root!.unmount());
  root = undefined;
  advance(10000);
  expect(bands.every((element) => !active(element))).toBe(true);
});

// A look's continuous shimmer (thinkingLook.ts; agentPane.display.thinking.shimmer "continuous").
const continuous = (element: HTMLElement) => element.classList.contains("is-shimmer-continuous");

test("a look's continuous shimmer loops in CSS on the wall clock's phase, with no timer, and goes back to the cadence", async () => {
  const now = jest.spyOn(Date, "now").mockReturnValue(10_300);
  configureThinkingLook({ [THINKING_SHIMMER_KEY]: "continuous", [THINKING_SHIMMER_PERIOD_KEY]: 1000 });
  const element = label();
  intersect(true);
  expect(continuous(element)).toBe(true);
  expect(active(element)).toBe(false);
  // 10300 % 1000: every label started now is 300 ms into the same pass.
  expect(element.style.getPropertyValue("--cv-shimmer-delay")).toBe("-300ms");
  expect(jest.getTimerCount()).toBe(0);
  // A new period restarts on the new phase.
  configureThinkingLook({ [THINKING_SHIMMER_KEY]: "continuous", [THINKING_SHIMMER_PERIOD_KEY]: 1600 });
  await Promise.resolve();
  expect(element.style.getPropertyValue("--cv-shimmer-delay")).toBe("-700ms");
  // The motion gate stops it like the cadence.
  document.documentElement.setAttribute("data-cmux-motion", "off");
  await Promise.resolve();
  expect(continuous(element)).toBe(false);
  document.documentElement.removeAttribute("data-cmux-motion");
  await Promise.resolve();
  expect(continuous(element)).toBe(true);
  intersect(false);
  expect(continuous(element)).toBe(false);
  intersect(true);
  // Back to the default: the one-second pass every four seconds.
  configureThinkingLook({});
  await Promise.resolve();
  expect(continuous(element)).toBe(false);
  expect(element.style.getPropertyValue("--cv-shimmer-delay")).toBe("");
  advance(600);
  expect(active(element)).toBe(true);
  now.mockRestore();
});

test("the thinking look's defaults write nothing on the root; out-of-range values keep the default", () => {
  configureThinkingLook({});
  const root = document.documentElement;
  expect(
    root.getAttributeNames().filter((name) => name.startsWith("data-thinking") || name === "data-jump-button"),
  ).toEqual([]);
  expect(root.style.length).toBe(0);
  expect(
    resolveThinkingLook({
      [THINKING_SHIMMER_KEY]: "sparkle",
      [THINKING_SHIMMER_PERIOD_KEY]: 50,
      [THINKING_SHIMMER_BAND_KEY]: 999,
      [THINKING_JUMP_BUTTON_KEY]: "rocket",
    }),
  ).toEqual(DEFAULT_THINKING_LOOK);
  configureThinkingLook({
    [THINKING_SHIMMER_KEY]: "continuous",
    [THINKING_SHIMMER_PERIOD_KEY]: 1250,
    [THINKING_SHIMMER_BAND_KEY]: 80,
    [THINKING_JUMP_BUTTON_KEY]: "dots",
  });
  expect(root.dataset.thinkingShimmer).toBe("continuous");
  expect(root.style.getPropertyValue("--cv-shimmer-period")).toBe("1250ms");
  expect(root.style.getPropertyValue("--cv-shimmer-band")).toBe("80px");
  expect(root.dataset.jumpButton).toBe("dots");
  expect(thinkingLook()).toEqual({
    shimmer: "continuous",
    periodMs: 1250,
    bandPx: 80,
    jumpButton: "dots",
    glyph: null,
    glyphKey: "",
    glyphSize: 0,
  });
  configureThinkingLook({});
  expect(root.style.length).toBe(0);
  expect(root.dataset.jumpButton).toBeUndefined();
});
