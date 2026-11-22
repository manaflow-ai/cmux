// The prompt rail's right-click filter and its edges (Leo, 2026-11-07: "when you right-click the left
// scroll rail, you should be able to ... filter out the other agent messages to only your own, or
// filtering out your own to only the agent messages", and "if you scroll to the very top, there should
// be no fade. But then as you scroll down, like gradually, there's more and more of a fade").
import { readFileSync } from "node:fs";
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { teardownDom } from "./support/domTeardown";
// The compact rail; the full-height map reads the same side (ScrollMap.tsx).
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

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
  // Reduce Motion: a step's scroll lands at once, with no glide.
  matchMedia: (query: string) => ({ matches: query.includes("reduce"), media: query }),
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport (the transcript's first height) over a long conversation,
// and a scroll offset the test moves as the reader would.
const VIEWPORT = 600;
let paneWidth = 1040;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
// Wide enough for the minimap's gutter (ThreadMinimap MIN_GUTTER).
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => paneWidth });
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

// A step's scroll (scrollTo) lands at once here.
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  this.scrollTop = typeof options === "number" ? 0 : (options?.top ?? 0);
} as typeof HTMLElement.prototype.scrollTo;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { setChatDisplay } = await import("../src/agent-session/acpmux/chatDisplay");

afterAll(async () => {
  setChatDisplay({});
  await teardownDom(saved, { window: dom.window, scope });
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
/// Twelve turns; every third prompt is another agent's message (a received one, promptSender).
const turns = Array.from({ length: 12 }, (_, index) => [
  index % 3 === 2
    ? {
        ...row(`user-${index + 1}`, "user", `Note ${index}`),
        incoming: { kind: "message", message: { name: "Grid fix", text: `Note ${index}`, raw: "" } },
      }
    : row(`user-${index + 1}`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat() as AcpmuxRow[];

const ticks = () => [...document.querySelectorAll<HTMLElement>("[data-tick]")];
const filterItems = () => [...document.querySelectorAll<HTMLElement>('[role="menuitemcheckbox"]')];
async function pick(label: string) {
  await act(async () => {
    ticks()[0]!.dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 20, clientY: 40 }),
    );
  });
  const items = filterItems();
  expect(items.map((item) => item.textContent?.replace("✓", ""))).toEqual([
    "Show All Messages",
    "Show Only My Messages",
    "Show Only Agent Messages",
    "Show Agent Replies",
    "Show Messages and Replies",
    "Show Turns with Errors",
    "Show Turns with Edits",
    "Show Turns with Tool Calls",
    "Show Turns with Subagents",
  ]);
  await act(async () => items.find((item) => item.textContent?.endsWith(label))!.click());
}

test("right-clicking the rail filters its ticks to my prompts or to other agents' messages, and back", async () => {
  setChatDisplay({ "agentPane.display.minimap": "compact" });
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(turns, new Set())}
          sessionId="rail-filter"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    // Unfiltered, the received messages each keep a tick (no two sit next to each other to fold).
    expect(ticks()).toHaveLength(12);
    await pick("Show Only My Messages");
    expect(ticks()).toHaveLength(8);
    await pick("Show Only Agent Messages");
    expect(ticks()).toHaveLength(4);
    // The menu checks the filter in use.
    await act(async () => {
      ticks()[0]!.dispatchEvent(new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    });
    expect(filterItems().map((item) => item.getAttribute("aria-checked"))).toEqual([
      "false",
      "false",
      "true",
      ...Array(6).fill("false"),
    ]);
    await act(async () => document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape" })));
    await pick("Show All Messages");
    expect(ticks()).toHaveLength(12);
  } finally {
    await act(async () => root.unmount());
    setChatDisplay({});
  }
});

test("Next Turn from above every kept prompt lands on the first one the filter keeps", async () => {
  // #39677 review F1: the first prompt Show Only Agent Messages keeps is the chat's third. With the
  // view at the top, above it, Next Turn counted from the first kept prompt as the one being read
  // and went on to the second.
  setChatDisplay({ "agentPane.display.minimap": "compact" });
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(turns, new Set())}
          sessionId="rail-filter-next"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const scrolled = async () => void scroller.dispatchEvent(new dom.window.Event("scroll"));
    await pick("Show Only Agent Messages");
    await act(async () => {
      scroller.scrollTop = 0;
      await scrolled();
    });
    const prompts = turns.filter((entry) => entry.kind === "user");
    /// The prompt being read: the last whose bubble is at or above 35 px under the view's top.
    const reading = () => {
      let read = 0;
      prompts.forEach((entry, index) => {
        const node = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${entry.id}"]`);
        const top =
          Number.parseFloat(node?.style.top ?? "") + (Number.parseFloat(node?.style.marginTop ?? "") || 0) - 16;
        if (Math.max(0, 16 + top - 35) <= scroller.scrollTop + 1) read = index;
      });
      return read;
    };
    expect(reading()).toBe(0);
    await act(async () => {
      dom.window.dispatchEvent(new dom.window.CustomEvent("cmux-acpmux-nextTurn"));
      await scrolled();
      await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
    });
    // The third prompt, the first other agent's message.
    expect(reading()).toBe(2);
  } finally {
    await act(async () => root.unmount());
    setChatDisplay({});
  }
});

test("a filter keeps its prompts in order and counts the earlier ones it keeps", async () => {
  const { filterTurns } = await import("../src/agent-session/acpmux/threadMinimap/model");
  const turn = (id: string, from?: string) => ({
    index: 0,
    id,
    key: id,
    prompt: id,
    reply: [],
    ...(from ? { from } : {}),
  });
  const all = [turn("a"), turn("b", "Grid fix"), turn("c"), turn("d", "Grid fix")];
  // An earlier indexed turn (before loadedStart 2) that a filter keeps still counts as earlier.
  expect(filterTurns(all, all, 2, "mine")).toEqual({
    turns: [all[0], all[2]],
    ticks: [all[0], all[2]],
    loadedStart: 1,
  });
  expect(filterTurns(all, all, 2, "agents").loadedStart).toBe(1);
  expect(filterTurns(all, all, 2, "all").turns).toBe(all);
});

test("each rail edge fades from nothing at its end to full a few rows on, like a wheel", async () => {
  const { railFadeReach, railFade, RAIL_FADE_RAMP, ROW_PITCH } =
    await import("../src/agent-session/acpmux/threadMinimap/model");
  const height = 240;
  const count = 100;
  const ramp = railFade(height) * RAIL_FADE_RAMP;
  const end = count * ROW_PITCH - height;
  // At the very top: no top fade; at the very bottom: no bottom fade.
  expect(railFadeReach(count, height, 0)).toEqual({ top: 0, bottom: 1 });
  expect(railFadeReach(count, height, end)).toEqual({ top: 1, bottom: 0 });
  // Halfway through the ramp from either end, half a fade.
  expect(railFadeReach(count, height, ramp / 2).top).toBeCloseTo(0.5);
  expect(railFadeReach(count, height, end - ramp / 2).bottom).toBeCloseTo(0.5);
  // It grows with every row scrolled, never in one step.
  const steps = Array.from(
    { length: ramp / ROW_PITCH + 1 },
    (_, row) => railFadeReach(count, height, row * ROW_PITCH).top,
  );
  for (let at = 1; at < steps.length; at += 1) expect(steps[at]! - steps[at - 1]!).toBeLessThanOrEqual(0.5);
});

// Leo, 2026-11-22: "if i scroll up in the scroll rail, the lower end should reflect that i'm not at the
// very bottom, and therefore have the same fade effect as the top does. likewise, when im at the top, it
// should def have the hard edge like when im at the bottom."
test("each rail end fades while the list or the chat has more past it, hard once both are at that end", async () => {
  const { railEdgeFades, railFade, ROW_PITCH } = await import("../src/agent-session/acpmux/threadMinimap/model");
  const height = 240;
  const count = 100;
  const end = count * ROW_PITCH - height;
  const rows = height / ROW_PITCH;
  const fade = railFade(height);
  /// The band a few rows in from the list's offset, clear of both fades.
  const mid = (top: number) => ({ first: top / ROW_PITCH + 8, last: top / ROW_PITCH + 10 });
  const at = (top: number, chatTop: number, chatBottom: number, band = mid(top)) =>
    railEdgeFades(band, count, height, top, { top: chatTop, bottom: chatBottom });
  // The chat at its top, the list at its top: a hard head, the foot full.
  expect(at(0, 0, 1)).toEqual({ top: false, bottom: true, reach: { top: 0, bottom: 1 } });
  // The chat at its bottom, the list at its end: a hard foot.
  expect(at(end, 1, 0)).toEqual({ top: true, bottom: false, reach: { top: 1, bottom: 0 } });
  // Scrolled up from the bottom with the list still at its end: the foot fades by the chat's reach.
  expect(at(end, 1, 0.4)).toEqual({ top: true, bottom: true, reach: { top: 1, bottom: 0.4 } });
  // Scrolled down from the top with the list still at its top: the head fades by the chat's reach.
  expect(at(0, 0.25, 1)).toEqual({ top: true, bottom: true, reach: { top: 0.25, bottom: 1 } });
  // The list wheeled off its end while the chat stays at the bottom: the foot fades for the rows below.
  expect(at(end - 400, 1, 0).bottom).toBe(true);
  // Never over the band: a lit prompt one row from the foot leaves the fade that row, a lit last
  // prompt at the rail's end leaves it hard, whatever the chat has below.
  const lastRows = { first: count - 3, last: count - 2 };
  expect(at(end, 1, 1, lastRows).reach.bottom).toBe(ROW_PITCH / fade);
  expect(at(end, 1, 1, { first: count - 2, last: count - 1 })).toMatchObject({ bottom: false });
  expect(at(0, 1, 1, { first: 0, last: 2 })).toMatchObject({ top: false });
  // The fade's depth moves with every pixel scrolled, never in one step.
  let was = at(end, 1, 0).reach.bottom;
  for (let px = 1; px <= 96; px += 1) {
    const now = at(end, 1, px / 96).reach.bottom;
    expect(now - was).toBeLessThanOrEqual(0.02 + 1e-9);
    was = now;
  }
  expect(rows).toBeGreaterThan(12);
});

test("the transcript's edges deepen as the view leaves each end", async () => {
  const { transcriptFadeReach, TRANSCRIPT_FADE_RAMP } = await import("../src/agent-session/acpmux/threadMinimap/model");
  expect(transcriptFadeReach(0)).toBe(0);
  expect(transcriptFadeReach(TRANSCRIPT_FADE_RAMP / 4)).toBe(0.25);
  expect(transcriptFadeReach(TRANSCRIPT_FADE_RAMP * 3)).toBe(1);
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(turns, new Set())}
          sessionId="transcript-fade"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    // A chat that opens at its end: no bottom fade there, and a top one at full depth far from the top.
    expect(scroller.style.getPropertyValue("--acpmux-fade-bottom-reach")).toBe("0");
  } finally {
    await act(async () => root.unmount());
  }
});

// Lawrence saw the rail's latest shadow (#42298) as a "weird timeline bg whiteness" (Leo: "maybe this is
// what lawrence meant? the scroll rail havign a bsckgorund?"): the rail and its pseudo-elements paint
// nothing of their own, at the latest message or scrolled up from it.
test("the rail draws no background or shadow while the view is scrolled up", async () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/threadMinimap/threadMinimap.css", import.meta.url),
    "utf8",
  ).replace(/\/\*[\s\S]*?\*\//g, "");
  // Every rule that targets the rail itself or its ::before/::after (with any attribute on the rail).
  const railRules = [...css.matchAll(/([^{}]+)\{([^}]*)\}/g)].filter(([, selector]) =>
    selector!
      .split(",")
      .some((part) => /\.acpmux-minimap__rail(\[[^\]]*\]|:not\([^)]*\))*(::?(before|after))?\s*$/.test(part.trim())),
  );
  expect(railRules.length).toBeGreaterThan(0);
  for (const [, selector, body] of railRules)
    expect({
      selector: selector!.trim(),
      paint: body!.match(/(^|;|\s)(background[\w-]*|box-shadow)\s*:[^;]*/g),
    }).toEqual({
      selector: selector!.trim(),
      paint: null,
    });
  setChatDisplay({ "agentPane.display.minimap": "compact" });
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(turns, new Set())}
          sessionId="rail-no-shadow"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    // Scrolled up to the top of the chat, far from the latest message.
    await act(async () => {
      scroller.scrollTop = 0;
      scroller.dispatchEvent(new dom.window.Event("scroll"));
    });
    const shell = document.querySelector<HTMLElement>(".acpmux-minimap")!;
    const rail = document.querySelector<HTMLElement>("nav.acpmux-minimap__rail")!;
    expect(rail).toBeTruthy();
    // No distance-driven paint on the rail: no shadow reach on its shell, no shadow variant on it.
    expect([...shell.style].filter((name) => name.includes("shadow"))).toEqual([]);
    expect([...rail.style].filter((name) => name.includes("shadow"))).toEqual([]);
    expect(rail.hasAttribute("data-shadow-variant")).toBe(false);
  } finally {
    await act(async () => root.unmount());
    setChatDisplay({});
  }
});

test("the rail shows the agent's replies, prompts and replies together, and only the turns of a kind", async () => {
  // Leo, 2026-11-21: "why cant you see an agents'? why cant you filter it? customize it immediately?"
  setChatDisplay({ "agentPane.display.minimap": "compact" });
  const failedAt = 5;
  const rows = turns.map((entry) =>
    entry.id === `t${failedAt}-end` ? { ...entry, status: "failed" } : entry,
  ) as AcpmuxRow[];
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId="rail-show"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    expect(ticks()).toHaveLength(12);
    await pick("Show Agent Replies");
    expect(ticks()).toHaveLength(12);
    expect(ticks().every((tick) => tick.dataset.reply !== undefined)).toBe(true);
    expect(ticks()[0]!.getAttribute("aria-label")).toStartWith("Reply 1 of 12");
    await pick("Show Messages and Replies");
    expect(ticks()).toHaveLength(24);
    expect(ticks().map((tick) => tick.dataset.reply !== undefined)).toEqual(
      Array.from({ length: 24 }, (_, at) => at % 2 === 1),
    );
    await pick("Show Turns with Errors");
    expect(ticks()).toHaveLength(1);
    // No turn here edits a file: that choice is offered disabled.
    await act(async () => {
      ticks()[0]!.dispatchEvent(new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    });
    const edits = filterItems().find((item) => item.textContent?.endsWith("Show Turns with Edits"))!;
    expect(edits.hasAttribute("disabled") || edits.getAttribute("aria-disabled") === "true").toBe(true);
    await act(async () => document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape" })));
    await pick("Show All Messages");
    expect(ticks()).toHaveLength(12);
  } finally {
    await act(async () => root.unmount());
    setChatDisplay({});
  }
});
