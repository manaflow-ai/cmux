// The agent chat ships with the wave (layout.experiment.ts, default `compact`): the Codex rail from
// #22228, one tick per prompt, the prompts on screen lit as a band that follows the scroll, the ticks
// under the pointer magnifying. Not the full-height map #22784 put in its place (Leo 2026-10-22: "Why
// did you turn it into a whole mini map? ... I didn't want the mini map."). With no experiment
// override the transcript draws the rail and no map, the rail sits over the transcript without moving
// its rows (no layout shift on a tab switch; Leo 2026-10-21: "THIS WHOLE THING CAUSES A LAYOUT SHIFT
// WHEN I SIMPLY SWITCH TO IT FROM ANOTEHR TAB"), and the rail's own list never draws a scroller.
import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { transcriptColumn } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { threadMinimapLayout } from "../src/agent-session/acpmux/threadMinimap/layout.experiment";
import { LIT_OPACITY, threadMinimapLit } from "../src/agent-session/acpmux/threadMinimap/lit.experiment";
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
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

test("the shipped arm is the wave", () => {
  expect(threadMinimapLayout.defaultArm).toBe("compact");
  expect(experimentArm(threadMinimapLayout, { overrides: {}, stored: {} })).toBe("compact");
  // Full and off stay selectable for dogfood (`cmux.experiments`).
  expect(Object.keys(threadMinimapLayout.arms).sort()).toEqual(["compact", "full", "off"]);
});

// The pane reads the arm from localStorage's `cmux.experiments` when the host sets none: a stored
// dogfood choice still wins over the default, and a stale or unknown one falls back to the wave.
test("a stored cmux.experiments choice is read, and an unknown one falls back to the wave", () => {
  const scope = globalThis as { localStorage?: Storage };
  const had = "localStorage" in scope;
  const before = scope.localStorage;
  scope.localStorage = dom.window.localStorage;
  try {
    const stored = (value: unknown) => {
      dom.window.localStorage.setItem("cmux.experiments", JSON.stringify(value));
      return experimentArm(threadMinimapLayout, { overrides: {} });
    };
    expect(stored({ "thread-minimap-layout": "full" })).toBe("full");
    expect(stored({ "thread-minimap-layout": "off" })).toBe("off");
    expect(stored({ "thread-minimap-layout": "minimap" })).toBe("compact");
    expect(stored({ "another-experiment": "full" })).toBe("compact");
    dom.window.localStorage.setItem("cmux.experiments", "not json");
    expect(experimentArm(threadMinimapLayout, { overrides: {} })).toBe("compact");
    dom.window.localStorage.removeItem("cmux.experiments");
    expect(experimentArm(threadMinimapLayout, { overrides: {} })).toBe("compact");
  } finally {
    dom.window.localStorage.removeItem("cmux.experiments");
    if (had) scope.localStorage = before;
    else delete scope.localStorage;
  }
});

/// Renders a 30-prompt chat scrolled to 900 px under `arms` (none: the default) and reads what the
/// left edge draws and where the rows sit.
async function render(arms?: Record<string, string>) {
  const scope = globalThis as { cmuxExperiments?: Record<string, string> };
  if (arms) scope.cmuxExperiments = arms;
  else delete scope.cmuxExperiments;
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(chat(30), new Set())}
        sessionId="minimap-default"
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    ),
  );
  const scroller = host.querySelector<HTMLElement>(".acpmux-scroll")!;
  expect(scroller).not.toBeNull();
  await act(async () => {
    scroller.scrollTop = 900;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
    await nextFrame();
  });
  const read = {
    ticks: host.querySelectorAll("[data-tick]").length,
    current: [...host.querySelectorAll<HTMLElement>('[data-tick][aria-current="true"]')].map(
      (tick) => tick.dataset.tick,
    ),
    map: host.querySelector(".acpmux-scrollmap, .acpmux-scrollmap__view, .acpmux-scrollmap__mark") !== null,
    rail: host.querySelector("nav.acpmux-minimap__rail") !== null,
    offset: scroller.scrollTop,
    rows: [...host.querySelectorAll<HTMLElement>(".acpmux-row")].map((row) => row.dataset.rowId),
    // Every inline placement in the transcript's content: its height, the thread's offset, the window's spacers.
    layout: [host.querySelector(".acpmux-spacer"), ...host.querySelectorAll(".acpmux-spacer [style]")].map((node) =>
      node?.getAttribute("style"),
    ),
  };
  return { host, root, scroller, read };
}
type Read = Awaited<ReturnType<typeof render>>["read"];

test("a long chat with no experiment override draws the wave rail, not the full-height map", async () => {
  const { host, root, scroller, read } = await render();
  try {
    expect(read.rail).toBe(true);
    expect(read.ticks).toBe(30);
    expect(read.map).toBe(false);
    // The band: the prompts on screen are lit.
    expect(read.current.length).toBeGreaterThan(0);
    // The rows keep the centered chat column: no gutter is reserved for a rail.
    const { inset, width } = transcriptColumn(PANE);
    expect(inset * 2 + width).toBe(PANE);
    // Previous Turn still steps the transcript.
    const before = scroller.scrollTop;
    await act(async () => void dom.window.dispatchEvent(new dom.window.CustomEvent("cmux-acpmux-previousTurn")));
    expect(scroller.scrollTop).toBeLessThan(before);
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});

test("the wave moves no row: the transcript lays out as it does with no minimap", async () => {
  const reads: Read[] = [];
  for (const arms of [undefined, { "thread-minimap-layout": "off" }]) {
    const { host, root, read } = await render(arms);
    reads.push(read);
    await act(async () => root.unmount());
    host.remove();
  }
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
  const [wave, off] = reads as [Read, Read];
  expect(wave.rail).toBe(true);
  expect(off.rail).toBe(false);
  expect(wave.rows.length).toBeGreaterThan(0);
  expect(wave.rows).toEqual(off.rows);
  expect(wave.layout).toEqual(off.layout);
  expect(wave.offset).toBe(off.offset);
});

test("the rail's list never draws a scroller of its own, and the rail takes no room", () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/threadMinimap/threadMinimap.css", import.meta.url),
    "utf8",
  ).replace(/\/\*[\s\S]*?\*\//g, "");
  const list = /\.acpmux-minimap__list\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(list).toMatch(/overflow:\s*hidden/);
  expect(list).not.toMatch(/overflow(-[xy])?:\s*(auto|scroll)/);
  // The rail sits over the transcript: sticky, no height of its own, so it takes no room in the layout.
  const shell = /\.acpmux-minimap\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(shell).toMatch(/position:\s*sticky/);
  expect(shell).toMatch(/height:\s*0/);
  // No solid accent line in the map: it draws in the theme's text tones only.
  expect(css).not.toMatch(/--(agent|cmux)-accent|Highlight\b|-webkit-focus-ring-color/);
});

// The lit band (the prompts on screen) carried over from #24065: 75% over the resting 40% (#22228 drew
// 60%, which barely showed where the reader was), still lit with the pointer on the rail, and gliding
// as it moves at rest. lit.experiment.ts keeps 60, 70, 75 and 85% side by side in the gallery.
test("the lit band ships at 75%, and each lit arm reaches the rail", async () => {
  expect(threadMinimapLit.defaultArm).toBe("lit-75");
  expect(experimentArm(threadMinimapLit, { overrides: {}, stored: {} })).toBe("lit-75");
  expect(Object.keys(threadMinimapLit.arms)).toEqual(Object.keys(LIT_OPACITY));
  for (const [arms, opacity] of [
    [undefined, 0.75],
    [{ "thread-minimap-lit": "lit-60" }, 0.6],
    [{ "thread-minimap-lit": "lit-85" }, 0.85],
  ] as const) {
    const { host, root } = await render(arms);
    try {
      const rail = host.querySelector<HTMLElement>("nav.acpmux-minimap__rail")!;
      expect(Number(rail.style.getPropertyValue("--acpmux-minimap-lit"))).toBe(opacity);
    } finally {
      await act(async () => root.unmount());
      host.remove();
    }
  }
  delete (globalThis as { cmuxExperiments?: unknown }).cmuxExperiments;
});

const minimapCss = () =>
  readFileSync(new URL("../src/agent-session/acpmux/threadMinimap/threadMinimap.css", import.meta.url), "utf8").replace(
    /\/\*[\s\S]*?\*\//g,
    "",
  );

test("the lit band draws at --acpmux-minimap-lit (75% by default) and stays lit with the pointer on the rail", () => {
  const css = minimapCss();
  const current =
    /\.acpmux-minimap__tick\[data-tone="current"\] \.acpmux-minimap__bar\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(current).toMatch(/opacity:\s*var\(--acpmux-minimap-lit,\s*0\.75\)/);
  // No rule takes the rail's band back to rest while a tick is hovered (the full map keeps its own).
  expect(css).not.toMatch(/\[data-hovering\][^{,]*\.acpmux-minimap__tick\[data-tone="current"\]/);
});

test("at rest the lit band glides as it moves (the wave); hover, scrub and Reduce Motion switch at once", () => {
  const css = minimapCss();
  // Only on the compact rail, at rest, outside a commit that changed the active row or the hover
  // (data-snap), and never on the active row itself.
  const atRest =
    '.acpmux-minimap__rail:not(.acpmux-scrollmap):not([data-hovering]):not([data-scrubbing]):not([data-reduce]):not([data-snap]) .acpmux-minimap__tick:not([data-tone="active"])';
  const block = (selector: string) =>
    new RegExp(`${selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*\\{([^}]*)\\}`).exec(css)?.[1] ?? "";
  const bar = block(`${atRest} .acpmux-minimap__bar`);
  expect(bar).toMatch(/transform var\(--cmux-motion-micro\)/);
  expect(bar).toMatch(/opacity var\(--cmux-motion-micro\)/);
  expect(block(atRest)).toMatch(/color var\(--cmux-motion-micro\)/);
  // Both rules sit inside the no-preference query, so Reduce Motion never runs them.
  for (const selector of [`${atRest} .acpmux-minimap__bar`, atRest]) {
    const at = css.indexOf(selector);
    expect(at).toBeGreaterThan(-1);
    const query = css.lastIndexOf("@media (prefers-reduced-motion: no-preference)", at);
    expect(query).toBeGreaterThan(-1);
    // No block closes the query between it and the rule.
    expect(css.slice(query, at)).not.toMatch(/\}\s*\}/);
  }
});

// Codex review of #24526: a key focusing a tick, or the focus leaving it, changes rows while the rail
// is at rest; those rows must switch at once, not glide. The commit that changes the active row marks
// the rail data-snap; the scroll's next band move drops the mark, so the band glides again.
test("focusing a tick or leaving it marks the rail data-snap, and the next band move clears it", async () => {
  const { host, root, scroller } = await render();
  try {
    const rail = () => host.querySelector<HTMLElement>("nav.acpmux-minimap__rail")!;
    expect(rail().hasAttribute("data-snap")).toBe(false);
    const tick = host.querySelector<HTMLElement>('[data-tick="2"]')!;
    await act(async () => tick.focus());
    expect(tick.dataset.tone).toBe("active");
    expect(rail().hasAttribute("data-snap")).toBe(true);
    const lit = () => host.querySelector('[data-tick][aria-current="true"]')?.getAttribute("data-tick");
    const before = lit();
    await act(async () => {
      scroller.scrollTop = 2400;
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await nextFrame();
    });
    expect(lit()).not.toBe(before);
    expect(rail().hasAttribute("data-snap")).toBe(false);
    await act(async () => tick.blur());
    expect(rail().hasAttribute("data-snap")).toBe(true);
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});
