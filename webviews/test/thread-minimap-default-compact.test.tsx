// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The agent chat ships the compact Codex rail (#22228) as its thread minimap (layout.experiment.ts,
// default `compact`). #22784 turned the default into a full-height map and #23735 then turned the
// minimap off; Leo (2026-10-21): "I didn't want the mini map", and the rail "didn't show the bottom
// bits being highlighted". So: the default arm is the compact rail and no full-height map is left;
// scrolled to the end, the rail's last ticks are lit and shown clear of its fade; scrolled to the
// start, its first ones are; the lit band glides (the wave) at rest; and the rail's list never
// draws a scroller of its own.
import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { transcriptColumn } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { threadMinimapLayout } from "../src/agent-session/acpmux/threadMinimap/layout.experiment";
import {
  minimapTurns,
  RAIL_FADE,
  railListTop,
  ROW_PITCH,
  visibleTurns,
} from "../src/agent-session/acpmux/threadMinimap/model";
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

test("the shipped arm is the compact rail, and no full-height map is left to pick", () => {
  expect(threadMinimapLayout.defaultArm).toBe("compact");
  expect(experimentArm(threadMinimapLayout, { overrides: {}, stored: {} })).toBe("compact");
  expect(Object.keys(threadMinimapLayout.arms).sort()).toEqual(["compact", "off"]);
  // A `full` stored before this change falls back to the default.
  expect(experimentArm(threadMinimapLayout, { overrides: {}, stored: { "thread-minimap-layout": "full" } })).toBe(
    "compact",
  );
});

/// `count` turns, each prompt 40 px tall and its reply `reply` px, as the layout's tops place them.
function laidOut(count: number, reply = 260) {
  const rows = chat(count);
  const tops = new Float64Array(rows.length);
  let y = 0;
  rows.forEach((item, index) => {
    tops[index] = y;
    y += item.kind === "user" ? 40 : item.kind === "assistant" ? reply : 0;
  });
  return { turns: minimapTurns(rows).turns, tops, total: y };
}

test("the band holds the first prompt at the top of the chat and the last at its end", () => {
  const viewport = 600;
  const { turns, tops, total } = laidOut(30);
  expect(visibleTurns(turns, tops, total, 0, viewport).first).toBe(0);
  expect(visibleTurns(turns, tops, total, total - viewport, viewport).last).toBe(turns.length - 1);
  // A last turn whose reply fills the view on its own is still the lit one.
  const tall = laidOut(30, 2_000);
  const end = visibleTurns(tall.turns, tall.tops, tall.total, tall.total - viewport, viewport);
  expect(end.first).toBe(turns.length - 1);
  expect(end.last).toBe(turns.length - 1);
});

test("a rail that scrolls shows the whole band clear of its fades, and its ends at the chat's ends", () => {
  const count = 80;
  const height = 400;
  const room = count * ROW_PITCH - height;
  // The chat's start and end: the list at its start and at its end, where no fade covers a row.
  expect(railListTop(0, 3, count, height, 250)).toBe(0);
  expect(railListTop(76, 79, count, height, 0)).toBe(room);
  expect(railListTop(79, 79, count, height, 120)).toBe(room);
  // The band's last row two rows short of the end: shown, not left under the bottom fade.
  const near = railListTop(75, 77, count, height, 300);
  expect(78 * ROW_PITCH).toBeLessThanOrEqual(near + height - (near < room ? RAIL_FADE : 0));
  // A band already clear of both fades leaves the list where it is...
  expect(railListTop(30, 33, count, height, 200)).toBe(200);
  // ...and one moving down a row carries the list by about a row, not a jump.
  const at = railListTop(52, 55, count, height, 200);
  const next = railListTop(53, 56, count, height, at);
  expect(next - at).toBeLessThanOrEqual(ROW_PITCH);
  expect(57 * ROW_PITCH).toBeLessThanOrEqual(next + height - RAIL_FADE);
  // A rail with room for every row never scrolls.
  expect(railListTop(10, 12, 20, 400, 0)).toBe(0);
});

/// The transcript's scroll height: its spacer is as tall as the layout.
const spacerHeight = () => parseFloat(document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);

async function scrollTo(scroller: HTMLElement, top: number) {
  await act(async () => {
    scroller.scrollTop = top;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
  });
}

test("a long chat with no override draws the compact rail: its first ticks lit at the top, its last at the end", async () => {
  // No host override and no stored key: the default arm.
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
  const prompts = 80;
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(chat(prompts), new Set())}
        sessionId="minimap-default-compact"
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    ),
  );
  try {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    expect(scroller).not.toBeNull();
    expect(document.querySelector(".acpmux-minimap__rail")).not.toBeNull();
    expect(document.querySelectorAll("[data-tick]").length).toBe(prompts);
    expect(document.querySelector(".acpmux-scrollmap")).toBeNull();
    const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    const lit = () =>
      [...document.querySelectorAll<HTMLElement>('[data-tick][aria-current="true"]')].map((tick) =>
        Number(tick.dataset.tick),
      );

    await scrollTo(scroller, spacerHeight() - VIEWPORT);
    expect(lit()).toContain(prompts - 1);
    // The rail scrolls (80 rows do not fit) and has come to its end: the last rows show, unfaded.
    expect(list.scrollTop).toBeGreaterThan(0);
    expect(list.hasAttribute("data-fade-bottom")).toBe(false);

    await scrollTo(scroller, 0);
    expect(lit()).toContain(0);
    expect(list.scrollTop).toBe(0);
    expect(list.hasAttribute("data-fade-top")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});

test("with the minimap off a chat draws no marks, keeps its column, and Previous Turn still steps", async () => {
  (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "off" };
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(chat(30), new Set())}
        sessionId="minimap-off"
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    ),
  );
  try {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    await scrollTo(scroller, 900);
    for (const selector of [".acpmux-minimap", ".acpmux-minimap__rail", "[data-tick]"])
      expect(document.querySelector(selector)).toBeNull();
    const { inset, width } = transcriptColumn(PANE);
    expect(inset * 2 + width).toBe(PANE);
    const before = scroller.scrollTop;
    await act(async () => void dom.window.dispatchEvent(new dom.window.CustomEvent("cmux-acpmux-previousTurn")));
    expect(scroller.scrollTop).toBeLessThan(before);
  } finally {
    await act(async () => root.unmount());
    delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
  }
});

const minimapCss = () =>
  readFileSync(new URL("../src/agent-session/acpmux/threadMinimap/threadMinimap.css", import.meta.url), "utf8").replace(
    /\/\*[\s\S]*?\*\//g,
    "",
  );

test("the minimap's list never draws a scroller of its own", () => {
  const css = minimapCss();
  const list = /\.acpmux-minimap__list\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(list).toMatch(/overflow:\s*hidden/);
  expect(list).not.toMatch(/overflow(-[xy])?:\s*(auto|scroll)/);
  // No solid accent line in the map: it draws in the theme's text tones only.
  expect(css).not.toMatch(/--(agent|cmux)-accent|Highlight\b|-webkit-focus-ring-color/);
});

test("at rest the lit band glides as it moves (the wave); under Reduce Motion it switches at once", () => {
  const css = minimapCss();
  const rest =
    /\.acpmux-minimap__rail:not\(\[data-hovering\]\):not\(\[data-scrubbing\]\):not\(\[data-reduce\]\) \.acpmux-minimap__bar\s*\{([^}]*)\}/.exec(
      css,
    )?.[1] ?? "";
  expect(rest).toMatch(/transform var\(--cmux-motion-micro\)/);
  expect(rest).toMatch(/opacity var\(--cmux-motion-micro\)/);
  const current =
    /\.acpmux-minimap__tick\[data-tone="current"\] \.acpmux-minimap__bar\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(Number(/opacity:\s*([\d.]+)/.exec(current)?.[1])).toBeGreaterThanOrEqual(0.7);
  expect(css).toMatch(/prefers-reduced-motion: reduce\)\s*\{\s*\.acpmux-minimap__rail \.acpmux-minimap__tick,/);
});
