// T5 frame probe: a reply that first appears in the turn-end snapshot must be painted at its
// settled place, and must not have ink over a kept row or copy while its box overlaps theirs.
// This uses a browser-shaped DOM and a deterministic compositor clock so the same rows can be
// compared before and after the fold change without relying on a real display refresh.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { captureTurnEnd, playTurnEnd, settleTurnEnd } from "../src/agent-session/acpmux/conversation/turnEndFold";
import { LIVE_THINKING } from "../src/agent-session/acpmux/conversation/turns";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

type Sample = {
  id: string;
  exists: boolean;
  left: number;
  top: number;
  bottom: number;
  width: number;
  translate: string;
  opacity: number;
  presentationOpacity: number;
  /** Group ink: the row's opacity (animations, a hold included) times its entrance's presentation. */
  ink: number;
  folding: boolean;
  ghosts: Array<{ top: number; opacity: number }>;
};

type Scenario = {
  name: string;
  /** Where the kept `worked-u` row was drawn before the turn ended, when it moves (a kept row sliding through the reply's place). */
  wasTop?: number;
  keptTail?: boolean;
  after: Array<{ id: string; kind: string; top: number; height: number; className?: string }>;
};

const row = (id: string, kind: AcpmuxRow["kind"] = "assistant"): AcpmuxRow => ({ id, version: 1, at: 1, kind });

const TIMES = Array.from({ length: 151 }, (_, index) => index * 4);

function page() {
  // Pin the shipped fade look so a local experiment override cannot change the probe.
  const dom = new JSDOM('<!doctype html><main data-turn-end-fold="fade"></main>', { pretendToBeVisual: true });
  const thread = dom.window.document.querySelector<HTMLElement>("main")!;
  const proto = dom.window.HTMLElement.prototype;
  const animations = new Map<
    HTMLElement,
    Array<{ keyframes: Keyframe[]; delay: number; duration: number; cancelled: boolean }>
  >();
  Object.defineProperty(proto, "offsetTop", {
    get() {
      return Number.parseFloat(this.style.top) || 0;
    },
  });
  Object.defineProperty(proto, "offsetHeight", {
    get() {
      return Number.parseFloat(this.style.height) || 0;
    },
  });
  Object.defineProperty(proto, "offsetParent", {
    get() {
      return thread;
    },
  });
  const sampleAnimation = (node: HTMLElement, time: number) => {
    const list = animations.get(node) ?? [];
    let translateY = 0;
    let opacity = 1;
    for (const animation of list) {
      if (animation.cancelled) continue;
      const progress = Math.max(0, Math.min(1, (time - animation.delay) / animation.duration));
      const first = animation.keyframes[0] ?? {};
      const last = animation.keyframes.at(-1) ?? {};
      if (first.translate !== undefined || last.translate !== undefined) {
        const parseY = (value: unknown) => Number.parseFloat(String(value ?? "0").split(/\s+/)[1] ?? "0") || 0;
        translateY = parseY(first.translate) + (parseY(last.translate) - parseY(first.translate)) * progress;
      }
      if (first.opacity !== undefined || last.opacity !== undefined)
        opacity =
          Number(first.opacity ?? opacity) +
          (Number(last.opacity ?? opacity) - Number(first.opacity ?? opacity)) * progress;
    }
    return { translateY, opacity };
  };
  proto.getBoundingClientRect = function () {
    const { translateY } = sampleAnimation(this, currentTime);
    const top = this.offsetTop + translateY;
    const height = this.offsetHeight;
    return { top, bottom: top + height, height, left: 24, right: 624, width: 600, x: 24, y: top, toJSON() {} };
  };
  proto.animate = function (keyframes, options) {
    const timing = (typeof options === "number" ? { duration: options } : (options ?? {})) as KeyframeAnimationOptions;
    const entry = {
      keyframes: keyframes as Keyframe[],
      delay: Number(timing.delay ?? 0),
      duration: Number(timing.duration ?? 1),
      cancelled: false,
    };
    const list = animations.get(this) ?? [];
    list.push(entry);
    animations.set(this, list);
    return {
      cancel() {
        entry.cancelled = true;
      },
      finish() {
        entry.cancelled = true;
      },
      onfinish: null,
      oncancel: null,
    } as unknown as Animation;
  };
  proto.getAnimations = function () {
    return [];
  };
  let currentTime = 0;
  const draw = (id: string, kind: string, top: number, height: number, className = "") => {
    const node = dom.window.document.createElement("article");
    node.className = `acpmux-row acpmux-${kind} ${className}`.trim();
    node.dataset.rowId = id;
    node.setAttribute("aria-posinset", String(thread.children.length + 1));
    node.style.top = `${top}px`;
    node.style.height = `${height}px`;
    const presentation = dom.window.document.createElement("div");
    presentation.className = "acpmux-row__message-presentation";
    node.append(presentation);
    thread.append(node);
    return node;
  };
  const frame = (time: number, id: string): Sample => {
    currentTime = time;
    const node = thread.querySelector<HTMLElement>(`[data-row-id="${id}"]`);
    const rect = node?.getBoundingClientRect();
    const animation = node ? sampleAnimation(node, time) : { opacity: 0, translateY: 0 };
    const presentation = node?.querySelector<HTMLElement>(".acpmux-row__message-presentation");
    // An entrance's own fade is its presentation; a row without one shows its group opacity alone.
    const presentationOpacity = node?.classList.contains("acpmux-row--message-enter") ? Math.min(1, time / 80) : 1;
    return {
      id,
      exists: Boolean(node),
      left: rect?.left ?? 0,
      top: rect?.top ?? 0,
      bottom: rect?.bottom ?? 0,
      width: rect?.width ?? 0,
      translate: node ? `0 ${animation.translateY}px` : "none",
      opacity: node ? animation.opacity : 0,
      presentationOpacity: presentation ? presentationOpacity : 0,
      ink: node && presentation ? animation.opacity * presentationOpacity : 0,
      folding: thread.hasAttribute("data-turn-end-folding"),
      ghosts: [...thread.querySelectorAll<HTMLElement>(".acpmux-row--fold-ghost")].map((ghost) => ({
        top: ghost.getBoundingClientRect().top,
        opacity: sampleAnimation(ghost, time).opacity,
      })),
    };
  };
  /** Every other child of the thread at `time` (kept rows and the fold's copies): its drawn box and ink. */
  const others = (time: number, exceptId: string) => {
    currentTime = time;
    return [...thread.children]
      .map((child) => child as HTMLElement)
      .filter((node) => node.dataset.rowId !== exceptId)
      .map((node) => {
        const rect = node.getBoundingClientRect();
        return {
          id: node.dataset.rowId ?? "copy",
          top: rect.top,
          bottom: rect.bottom,
          ink: sampleAnimation(node, time).opacity,
        };
      });
  };
  return { dom, thread, draw, frame, others };
}

function runScenario(scenario: Scenario) {
  const p = page();
  p.draw("working-u", "working", 0, 34);
  p.draw("work", "activity", 34, 260);
  p.draw("answer-old", "assistant", 294, 120);
  p.draw(LIVE_THINKING, "thinking", 414, 22);
  if (scenario.wasTop !== undefined) p.draw("worked-u", "worked", scenario.wasTop, 34);
  if (scenario.keptTail) p.draw("tail", "assistant", 700, 34);
  const capture = captureTurnEnd(
    p.thread,
    p.thread,
    [row("worked-u", "worked"), row("answer-old"), ...(scenario.keptTail ? [row("tail")] : [])],
    "chat",
  )!;
  p.thread.replaceChildren();
  for (const item of scenario.after) p.draw(item.id, item.kind, item.top, item.height, item.className);
  const fold = playTurnEnd(p.thread, capture, "chat", p.thread);
  const samples = TIMES.map((time) => p.frame(time, "answer-new"));
  // Assertion (b): the arriving row's ink over a kept row or copy with ink, as each is drawn that frame.
  const overlap = samples.map((sample, index) => {
    if (!sample.exists || sample.ink <= 0.05) return { px: 0, with: "" };
    let px = 0;
    let who = "";
    for (const other of p.others(TIMES[index]!, "answer-new")) {
      if (other.ink <= 0.05) continue;
      const shared = Math.min(sample.bottom, other.bottom) - Math.max(sample.top, other.top);
      if (shared > px) [px, who] = [shared, other.id];
    }
    return { px, with: who };
  });
  const final = samples.at(-1)!;
  const away = samples.filter((sample) => sample.exists && Math.abs(sample.top - final.top) > 2);
  const inkIndex = samples.findIndex((sample) => sample.ink > 0.05);
  const result = {
    name: scenario.name,
    firstPaintedOffsetPx: Math.abs(samples.find((sample) => sample.exists)!.top - final.top),
    inkWhileAway: Math.max(0, ...away.map((sample) => sample.ink)),
    framesAway: away.length,
    inkStartMs: inkIndex < 0 ? null : TIMES[inkIndex]!,
    overlapFrames: overlap.filter((entry) => entry.px > 0.5).length,
    overlapMaxPx: Math.max(0, ...overlap.map((entry) => entry.px)),
    overlapWith: overlap.find((entry) => entry.px > 0.5)?.with ?? "",
    leftOffsetPx: Math.max(0, ...away.map((sample) => Math.abs(sample.left - final.left))),
    widthOffsetPx: Math.max(0, ...away.map((sample) => Math.abs(sample.width - final.width))),
    samples,
  };
  settleTurnEnd(p.thread, fold);
  p.dom.window.close();
  return result;
}

const scenarios: Scenario[] = [
  {
    name: "scripted-turn",
    after: [
      { id: "worked-u", kind: "worked", top: 300, height: 34 },
      { id: "answer-new", kind: "assistant", top: 334, height: 120 },
    ],
  },
  {
    name: "same-snapshot-final-reply",
    after: [
      { id: "worked-u", kind: "worked", top: 300, height: 34 },
      { id: "answer-new", kind: "assistant", top: 334, height: 120 },
    ],
  },
  {
    name: "streaming-reply-renamed-at-settle",
    after: [
      { id: "worked-u", kind: "worked", top: 300, height: 34 },
      { id: "answer-new", kind: "assistant", top: 334, height: 120, className: "acpmux-row--message-enter" },
    ],
  },
  {
    name: "text-wrap-up-result",
    after: [
      { id: "worked-u", kind: "worked", top: 360, height: 34 },
      { id: "answer-new", kind: "assistant", top: 394, height: 160 },
      { id: "next-step", kind: "next-step", top: 554, height: 72 },
    ],
  },
  {
    name: "next-turn-within-5ms",
    after: [
      { id: "worked-u", kind: "worked", top: 420, height: 34 },
      { id: "answer-new", kind: "assistant", top: 454, height: 120 },
      { id: "next-line", kind: "notice", top: 574, height: 22 },
    ],
  },
  {
    name: "next-turn-line-after-reply",
    after: [
      { id: "worked-u", kind: "worked", top: 300, height: 34 },
      { id: "answer-new", kind: "assistant", top: 334, height: 120 },
      { id: "next-line", kind: "notice", top: 454, height: 22 },
    ],
  },
  {
    name: "long-reply-taller-than-viewport",
    after: [
      { id: "worked-u", kind: "worked", top: 760, height: 34 },
      { id: "answer-new", kind: "assistant", top: 794, height: 1_600 },
    ],
  },
  {
    name: "long-turn-30-tool-rows",
    after: [
      { id: "worked-u", kind: "worked", top: 1_200, height: 34 },
      { id: "answer-new", kind: "assistant", top: 1_234, height: 120 },
    ],
  },
  {
    name: "long-fold",
    after: [
      { id: "worked-u", kind: "worked", top: 900, height: 34 },
      { id: "answer-new", kind: "assistant", top: 934, height: 900 },
    ],
  },
  {
    name: "background-finish-hidden-reply",
    after: [
      { id: "worked-u", kind: "worked", top: 500, height: 34 },
      { id: "answer-new", kind: "assistant", top: 534, height: 540 },
    ],
  },
  {
    name: "kept-row-slides-up-through-reply",
    wasTop: 520,
    after: [
      { id: "worked-u", kind: "worked", top: 300, height: 34 },
      { id: "answer-new", kind: "assistant", top: 334, height: 120 },
    ],
  },
  {
    name: "kept-row-crosses-reply-with-own-entrance",
    wasTop: 520,
    keptTail: true,
    after: [
      { id: "worked-u", kind: "worked", top: 300, height: 34 },
      { id: "answer-new", kind: "assistant", top: 334, height: 120, className: "acpmux-row--message-enter" },
      { id: "tail", kind: "assistant", top: 700, height: 34 },
    ],
  },
  {
    name: "kept-row-crosses-reply-with-row-entrance",
    wasTop: 520,
    keptTail: true,
    after: [
      { id: "worked-u", kind: "worked", top: 300, height: 34 },
      { id: "answer-new", kind: "assistant", top: 334, height: 120, className: "acpmux-row--enter" },
      { id: "tail", kind: "assistant", top: 700, height: 34 },
    ],
  },
  {
    name: "kept-row-slides-up-short",
    wasTop: 380,
    after: [
      { id: "worked-u", kind: "worked", top: 300, height: 34 },
      { id: "answer-new", kind: "assistant", top: 334, height: 120 },
    ],
  },
  {
    name: "sr2-coord-197051-recording",
    after: [
      { id: "worked-u", kind: "worked", top: 640, height: 34 },
      { id: "answer-new", kind: "assistant", top: 674, height: 320 },
    ],
  },
];

for (const scenario of scenarios)
  test(`T5: ${scenario.name}: new reply stays in place without overlapping`, () => {
    const result = runScenario(scenario);
    console.log(`reply-settle ${JSON.stringify({ ...result, samples: undefined })}`);
    expect(result.firstPaintedOffsetPx, result.name).toBeLessThanOrEqual(0.5);
    expect(result.inkWhileAway, result.name).toBeLessThanOrEqual(0.05);
    expect(result.overlapFrames, `${result.name} overlaps ${result.overlapWith}`).toBe(0);
  });
