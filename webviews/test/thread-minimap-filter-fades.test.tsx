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
import { railFrame } from "./support/railFrame";
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
    "Show Messages",
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
    await railFrame();
    // The default rail draws the person's prompts only: another agent's message has no tick (Leo,
    // 2026-11-27: "non-user messages shouldnt appear in the scroll rail anymore").
    expect(ticks()).toHaveLength(8);
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
    await pick("Show Messages");
    expect(ticks()).toHaveLength(8);
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
    await railFrame();
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const scrolled = async () => void scroller.dispatchEvent(new dom.window.Event("scroll"));
    await pick("Show Only Agent Messages");
    await act(async () => {
      scroller.scrollTop = 0;
      await scrolled();
      // The transcript re-windows to the new top over the next frames; its rows at the top mount then.
      for (let frame = 0; frame < 5; frame += 1)
        await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
    });
    const prompts = turns.filter((entry) => entry.kind === "user");
    /// The prompt being read: the last whose turn's first row is at or above 35 px under the view's top.
    /// A received message's turn opens on its "Worked for" line (#49052), which holds the message under
    /// it, so the line, not the bubble, is where the rail lands the turn.
    const reading = () => {
      let read = 0;
      prompts.forEach((entry, index) => {
        const node =
          document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="worked-${entry.id}"]`) ??
          document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${entry.id}"]`);
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

test("the default rail keeps only the person's prompts, and every prompt when none is", async () => {
  const { personEntries } = await import("../src/agent-session/acpmux/threadMinimap/model");
  const turn = (id: string, agent?: boolean) => ({
    index: 0,
    id,
    key: id,
    prompt: id,
    reply: [],
    ...(agent ? { agent: true as const } : {}),
  });
  const all = [turn("a"), turn("notice", true), turn("b"), turn("peer", true)];
  const kept = personEntries(all, all);
  expect(kept.ticks.map((tick) => tick.id)).toEqual(["a", "b"]);
  expect(kept.turns.map((entry) => entry.id)).toEqual(["a", "b"]);
  // The same lists while the lists they are read from are: a streamed token renders no tick.
  expect(personEntries(all, all).ticks).toBe(kept.ticks);
  const people = [turn("a"), turn("b")];
  expect(personEntries(people, people).ticks).toBe(people);
  const agents = [turn("x", true), turn("y", true)];
  expect(personEntries(agents, agents).ticks).toBe(agents);
});

test("a prompt is the person's unless an agent, a notice, bookkeeping or a task result sent it", async () => {
  const { isPersonPrompt } = await import("../src/agent-session/acpmux/threadMinimap/model");
  const prompt = (extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({ ...row("user-1", "user", "hi"), ...extra });
  const message = (fromPerson?: true) =>
    ({ kind: "message", message: { name: "guest", text: "hi", raw: "hi", ...(fromPerson && { fromPerson }) } }) as AcpmuxRow["incoming"];
  expect(isPersonPrompt(prompt())).toBe(true);
  expect(isPersonPrompt(prompt({ incoming: message(true) }))).toBe(true);
  expect(isPersonPrompt(prompt({ incoming: message() }))).toBe(false);
  expect(isPersonPrompt(prompt({ incoming: { kind: "notice", text: "Background build finished" } }))).toBe(false);
  expect(isPersonPrompt(prompt({ incoming: { kind: "hidden" } }))).toBe(false);
  expect(isPersonPrompt(prompt({ inBackground: "bg-1" }))).toBe(false);
  expect(isPersonPrompt(prompt({ received: {} as AcpmuxRow["received"] }))).toBe(false);
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
    await railFrame();
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
    await railFrame();
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
    await railFrame();
    expect(ticks()).toHaveLength(8);
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
    await pick("Show Messages");
    expect(ticks()).toHaveLength(8);
  } finally {
    await act(async () => root.unmount());
    setChatDisplay({});
  }
});
