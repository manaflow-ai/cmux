// The agent chat ships with no thread minimap (layout.experiment.ts, default `off`; Leo 2026-10-21 on
// the nightly: "HOW DID THIS SCROLL THING GET IN AGAIN"). With no experiment override the transcript
// draws no full-height map, no compact rail and no marks down its left edge, keeps its rows centered
// in the same column (no gutter reserved for a rail), and Previous and Next Turn still step it.
// The minimap's own list never draws a scroller of its own when an arm turns it on.
import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { transcriptColumn } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { threadMinimapLayout } from "../src/agent-session/acpmux/threadMinimap/layout.experiment";
import { experimentArm } from "../src/experiments/experiment";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  matchMedia: (query: string) => ({ matches: query.includes("reduce"), media: query }),
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport in a pane wide enough for any rail (1040 px).
const VIEWPORT = 600;
const PANE = 1040;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => PANE });
const offsets = new WeakMap<object, number>();
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, value);
  },
});
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  this.scrollTop = typeof options === "number" ? 0 : (options?.top ?? 0);
} as typeof HTMLElement.prototype.scrollTo;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const chat = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    row(`user-${index + 1}`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
    { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ]).flat();

test("the shipped arm is off", () => {
  expect(threadMinimapLayout.defaultArm).toBe("off");
  expect(experimentArm(threadMinimapLayout, { overrides: {}, stored: {} })).toBe("off");
  // Full and compact stay selectable for dogfood (`cmux.experiments`).
  expect(Object.keys(threadMinimapLayout.arms).sort()).toEqual(["compact", "full", "off"]);
});

test("a long chat with no experiment override draws no minimap and no marks down the left edge", async () => {
  // No host override and no stored key: the default arm.
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(chat(30), new Set())}
        sessionId="minimap-default-off"
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    ),
  );
  try {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    expect(scroller).not.toBeNull();
    await act(async () => {
      scroller.scrollTop = 900;
      scroller.dispatchEvent(new dom.window.Event("scroll"));
    });
    for (const selector of [
      ".acpmux-minimap",
      ".acpmux-minimap__rail",
      ".acpmux-minimap__list",
      ".acpmux-scrollmap",
      ".acpmux-scrollmap__view",
      ".acpmux-scrollmap__mark",
      "[data-tick]",
    ])
      expect(document.querySelector(selector)).toBeNull();
    expect(document.querySelector('nav[aria-label]')).toBeNull();
    // The rows keep the centered chat column: no gutter is reserved for a rail.
    const { inset, width } = transcriptColumn(PANE);
    expect(inset * 2 + width).toBe(PANE);
    // Previous Turn still steps the transcript with the minimap off.
    const before = scroller.scrollTop;
    await act(async () => void dom.window.dispatchEvent(new dom.window.CustomEvent("cmux-acpmux-previousTurn")));
    expect(scroller.scrollTop).toBeLessThan(before);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the minimap's list never draws a scroller of its own", () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/threadMinimap/threadMinimap.css", import.meta.url),
    "utf8",
  ).replace(/\/\*[\s\S]*?\*\//g, "");
  const list = /\.acpmux-minimap__list\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(list).toMatch(/overflow:\s*hidden/);
  expect(list).not.toMatch(/overflow(-[xy])?:\s*(auto|scroll)/);
  // No solid accent line in the map: it draws in the theme's text tones only.
  expect(css).not.toMatch(/--(agent|cmux)-accent|Highlight\b|-webkit-focus-ring-color/);
});
