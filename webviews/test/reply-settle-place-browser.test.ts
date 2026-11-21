// T5 frame probe: a reply that first appears in the turn-end snapshot must be painted at its
// settled place, and must not have ink over a kept row or copy while its box overlaps theirs.
// This uses a browser-shaped DOM and a deterministic compositor clock so the same rows can be
// compared before and after the fold change without relying on a real display refresh.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { captureTurnEnd, playTurnEnd, settleTurnEnd } from "../src/agent-session/acpmux/conversation/turnEndFold";
import { bezierAt, parseBezier } from "../src/ui/cubicBezier";
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
  after: Array<{ id: string; kind: string; top: number; height: number; className?: string }>;
};

const row = (id: string, kind: AcpmuxRow["kind"] = "assistant"): AcpmuxRow => ({ id, version: 1, at: 1, kind });

const TIMES = Array.from({ length: 151 }, (_, index) => index * 4);

function page() {
  const dom = new JSDOM("<!doctype html><main></main>", { pretendToBeVisual: true });
  const thread = dom.window.document.querySelector<HTMLElement>("main")!;
  const proto = dom.window.HTMLElement.prototype;
  const animations = new Map<
    HTMLElement,
    Array<{ keyframes: Keyframe[]; delay: number; duration: number; easing: string; cancelled: boolean }>
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
      const linear = Math.max(0, Math.min(1, (time - animation.delay) / animation.duration));
      // On the animation's own curve, as a browser draws it (linear where it names none).
      const curve = parseBezier(animation.easing);
      const progress = curve ? bezierAt(curve, linear) : linear;
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
      easing: String(timing.easing ?? "linear"),
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
  // A browser's computed opacity includes the row's running animations (a fold's hold at no ink).
  const computed = dom.window.getComputedStyle.bind(dom.window);
  dom.window.getComputedStyle = ((node: Element, pseudo?: string | null) => {
    const style = computed(node, pseudo);
    if (!animations.has(node as HTMLElement)) return style;
    const { opacity } = sampleAnimation(node as HTMLElement, currentTime);
    return new Proxy(style, {
      get: (target, key) => (key === "opacity" ? String(opacity) : Reflect.get(target, key)),
    });
  }) as typeof dom.window.getComputedStyle;
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
  const at = (time: number) => {
    currentTime = time;
  };
  return { dom, thread, draw, frame, others, at };
}

function runScenario(scenario: Scenario) {
  const p = page();
  p.draw("working-u", "working", 0, 34);
  p.draw("work", "activity", 34, 260);
  p.draw("answer-old", "assistant", 294, 120);
  p.draw(LIVE_THINKING, "thinking", 414, 22);
  if (scenario.wasTop !== undefined) p.draw("worked-u", "worked", scenario.wasTop, 34);
  const capture = captureTurnEnd(p.thread, p.thread, [row("worked-u", "worked"), row("answer-old")], "chat")!;
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

test("T5: every reply new at settle paints in its final place, with no ink over a kept row", () => {
  const report = scenarios.map(runScenario);
  for (const result of report) console.log(`reply-settle ${JSON.stringify({ ...result, samples: undefined })}`);
  for (const result of report) {
    expect(result.firstPaintedOffsetPx, result.name).toBeLessThanOrEqual(0.5);
    expect(result.inkWhileAway, result.name).toBeLessThanOrEqual(0.05);
    expect(result.overlapFrames, `${result.name} overlaps ${result.overlapWith}`).toBe(0);
  }
});

// A turn that ends while the fold before still holds a reply at no ink (the reply waits for a kept
// row sliding up through its box): the next fold starts from what each row drew then. Started from
// its box, the held reply came in at full ink under the kept row still sliding through it (Leo,
// 2026-11-21: "it was in the agent chat gui the text goes atop one another"; agent-pane-stream-row-
// overlap, agent messages lagging: two replies drawn at one place, 52 px of ink).
function runChained(takesHeldReply: boolean) {
  const p = page();
  p.draw("working-u", "working", 0, 34);
  p.draw("work", "activity", 34, 260);
  p.draw("answer-old", "assistant", 294, 120);
  p.draw(LIVE_THINKING, "thinking", 414, 22);
  p.draw("worked-u", "worked", 520, 34);
  const first = captureTurnEnd(p.thread, p.thread, [row("worked-u", "worked"), row("answer-old")], "chat")!;
  p.thread.replaceChildren();
  p.draw("worked-u", "worked", 300, 34);
  p.draw("answer-new", "assistant", 334, 120);
  p.draw(LIVE_THINKING, "thinking", 454, 22);
  const firstFold = playTurnEnd(p.thread, first, "chat", p.thread);
  // The next turn ends while the reply still holds at no ink, the kept row drawn inside its box.
  const endsAt = TIMES.find((time) => {
    p.at(time);
    const kept = p.thread.querySelector<HTMLElement>('[data-row-id="worked-u"]')!.getBoundingClientRect();
    return p.frame(time, "answer-new").ink <= 0.05 && kept.top > 340 && kept.top < 440;
  });
  expect(endsAt, "the first fold holds the reply while the kept row slides through it").toBeDefined();
  p.at(endsAt!);
  const after = takesHeldReply
    ? [row("worked-u", "worked"), row("worked-v", "worked")]
    : [row("worked-u", "worked"), row("answer-new"), row("worked-v", "worked")];
  const second = captureTurnEnd(p.thread, p.thread, after, "chat")!;
  settleTurnEnd(p.thread, firstFold);
  p.thread.replaceChildren();
  p.draw("worked-u", "worked", 300, 34);
  if (!takesHeldReply) p.draw("answer-new", "assistant", 334, 120);
  p.draw("worked-v", "worked", takesHeldReply ? 334 : 454, 34);
  const fold = playTurnEnd(p.thread, second, "chat", p.thread);
  let overlapFrames = 0;
  let overlapMaxPx = 0;
  for (const time of TIMES) {
    const drawn = p.others(time, "");
    for (const a of drawn)
      for (const b of drawn) {
        if (a === b || a.ink <= 0.05 || b.ink <= 0.05 || a.top > b.top) continue;
        const shared = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
        if (shared > 0.5) {
          overlapFrames += 1;
          overlapMaxPx = Math.max(overlapMaxPx, shared);
        }
      }
  }
  settleTurnEnd(p.thread, fold);
  p.dom.window.close();
  return { overlapFrames, overlapMaxPx };
}

test("a turn ending while the last fold holds a reply hidden draws no row over another", () => {
  for (const takesHeldReply of [false, true]) {
    const result = runChained(takesHeldReply);
    console.log(`reply-settle chained ${JSON.stringify({ takesHeldReply, ...result })}`);
    expect(result, `takes the held reply: ${takesHeldReply}`).toEqual({ overlapFrames: 0, overlapMaxPx: 0 });
  }
});
