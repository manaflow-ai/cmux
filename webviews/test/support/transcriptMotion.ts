// The transcript's one motion detector (hq#18554 ask 3). Leo, 2026-11-22: "IT JUMPS ... DON'T JUMP / FIX
// THE ANIMATIONS / FIX THE LOGIC / AND / WHEN A TURN BY AN AGENT END / STOP ADDING DINGLEBERRIES OF TOOL
// CALLS ... THAT SHIFTS POORLY. IF IT NEEDS TO SHIFT, IT SHIFTS GRACEFULLY. THAT'S THE GOAL. / AND I
// SHOULDN'T HAVE TO KEEP IDENTIFYING THIS / MATHEMATICALLY, ALL OF THESE SHOULD BE FLAGGABLE".
//
// The page side (`defineTranscriptMotion`) reads every painted frame: the drawn box of every transcript
// element in view (each row, the composer's card and the bottom dock, the turn-end fold's card), the
// scroller's offset, the geometry animations running (with their easing and length), and which elements
// something touched since the frame before. An element is touched when the DOM inside it changed (a node
// added or removed, text, an attribute other than `style`: the records a step applies, a stream's reveal),
// or it mounted. It is the popup recorder's attribution (popupStill.ts, cmux#49879) per element: input
// excuses only what it was given to, and a step excuses only the elements it changed. A move made by
// writing `style` from script is no touch: it is a move, and it is judged as one.
//
// The node side (`transcriptMoves`, pure) names, frame by frame:
// - `move`: an element no step touched (in this frame or the one before) and no animation moves, that is
//   drawn more than 1 px from where it was drawn the frame before. The reader's own scroll (input) is
//   taken out first: their wheel moves every row, and that is theirs.
// - `resize`: the same element's box more than 1 px taller, shorter, wider or narrower.
// - `off-curve`: a running animation that moves geometry (transform, translate, a height, a clip) on
//   another easing than the house's (motion/scale.generated.ts: the settle, the send curve, the ease-out,
//   the spring, the follow's arrival step) or longer than the scale's ceiling (MOTION_MS.large).
// Each flag names what landed just before it (the step's marks) and what grew beside it in the same frame
// (its cause), so a table can say which steps make the jumps.
//
// The layout-motion contract (handbook undeclared-layout-move; cmux#48683) is the same idea for every
// surface, with declared moves; its judge is unmerged. This detector needs no declaration: in a transcript
// every move must either be the touched element's own, or ride an animation on the house curve.
import { MOTION_EASE_OUT, MOTION_MS, MOTION_SETTLE, MOTION_SPRING } from "../../src/motion/scale.generated";
import { ARRIVAL_EASE } from "../../src/agent-session/acpmux/conversation/followChase";

/** A move or resize under this (px) in one frame is layout rounding (the brief's "more than 1 px"). */
export const STILL_PX = 1;
/** A touch excuses the frame it landed in and the next: React commits, then the layout reads it. */
export const TOUCH_FRAMES = 2;
/** The reader's input excuses their scroll for this long (ms): a wheel's momentum, a programmatic jump. */
export const INPUT_MS = 250;
/** The house curves (normalized): every geometry animation runs on one of them. */
export const HOUSE_EASINGS = [MOTION_SETTLE, MOTION_EASE_OUT, MOTION_SPRING, ARRIVAL_EASE];
/** The ceiling of any house move (ms): "no house move outlasts the large step" (scale.generated.ts). */
export const HOUSE_MAX_MS = MOTION_MS.large;

export type Box = [x: number, y: number, w: number, h: number];
export type MotionFrameRecord = {
  /** ms since recording started. */
  t: number;
  scrollTop: number;
  scrollHeight: number;
  clientHeight: number;
  /** Each tracked element drawn in view: key -> [box, kind]. */
  els: Record<string, [box: Box, kind: string]>;
  /** Keys something touched since the last frame (DOM inside it changed, or it mounted). */
  touched: string[];
  /** Keys a running geometry animation moves (on the element, or on an element holding it). */
  animated: string[];
  /** Marks (steps, input) since the last frame. */
  marks: string[];
};
export type AnimationSeen = {
  /** The animated element: a tracked key, or `tag.class` for a container (the thread, the stack). */
  target: string;
  properties: string[];
  duration: number;
  easing: string;
  /** Frame index first seen running. */
  frame: number;
};
export type MotionRecord = { frames: MotionFrameRecord[]; animations: AnimationSeen[]; inputs: number[] };

export type TranscriptMotionOptions = {
  scroller: string;
  /** Selectors of tracked elements; each match is keyed by its `data-row-id` or a stable id. */
  tracked: { selector: string; kind: string; key?: string }[];
};

/** What the transcript's own pages track: every row, the composer's card and dock, the fold card. */
export const TRANSCRIPT_MOTION: TranscriptMotionOptions = {
  scroller: ".acpmux-scroll",
  tracked: [
    { selector: ".acpmux-thread > .acpmux-row", kind: "row" },
    { selector: ".acpmux-thread > .acpmux-fold-card", kind: "fold-card", key: "fold-card" },
    { selector: ".acpmux-main > .acpmux-dock", kind: "dock", key: "dock" },
    { selector: ".acpmux-composer-box", kind: "composer", key: "composer" },
  ],
};

declare global {
  interface Window {
    __transcriptMotion?: {
      start(): void;
      stop(): MotionRecord;
      /** A step landed, or the reader's input (`input`, or `input:...`). */
      mark(label: string): void;
      count(): number;
    };
  }
}

/** The page side; closes over nothing, so a test can inject it (`page.addInitScript`) and a harness can call it. */
export function defineTranscriptMotion(options: TranscriptMotionOptions) {
  if (window.__transcriptMotion) return;
  const GEOMETRY =
    /^(transform|translate|scale|rotate|top|left|right|bottom|height|width|min-height|max-height|margin.*|padding.*|clip-path|inset.*|grid-template-rows|offset.*)$/;
  const camel = (name: string) => name.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
  const ids = new WeakMap<Element, string>();
  const animIds = new WeakMap<Animation, number>();
  let nextId = 0;
  let nextAnim = 0;
  const selectorAll = options.tracked.map((entry) => entry.selector).join(", ");
  const entryOf = (element: Element) => options.tracked.find((entry) => element.matches(entry.selector));
  const keyOf = (element: Element): string => {
    let key = ids.get(element);
    if (key) return key;
    const entry = entryOf(element);
    const rowId = (element as HTMLElement).dataset?.rowId;
    key = entry?.key ?? (rowId ? `row:${rowId}` : `${entry?.kind ?? "el"}#${(nextId += 1)}`);
    ids.set(element, key);
    return key;
  };
  /** The tracked element holding `node`, if any (a container holds none). */
  const holder = (node: Node | null): Element | null => {
    const element = node instanceof Element ? node : (node?.parentElement ?? null);
    return element?.closest(selectorAll) ?? null;
  };
  let recording = false;
  let origin = 0;
  let frames: MotionFrameRecord[] = [];
  let animations: AnimationSeen[] = [];
  let inputs: number[] = [];
  let touched = new Set<string>();
  let marks: string[] = [];
  const observer = new MutationObserver((list) => {
    if (!recording) return;
    for (const mutation of list) {
      if (mutation.type === "attributes" && mutation.attributeName === "style") continue;
      const owner = holder(mutation.target);
      if (owner) touched.add(keyOf(owner));
      for (const node of mutation.addedNodes) {
        if (!(node instanceof Element)) continue;
        if (node.matches(selectorAll)) touched.add(keyOf(node));
        for (const inner of node.querySelectorAll(selectorAll)) touched.add(keyOf(inner));
      }
    }
  });
  const onInput = () => {
    if (recording) inputs.push(performance.now() - origin);
  };
  for (const kind of ["wheel", "keydown", "pointerdown", "touchstart"])
    addEventListener(kind, onInput, { capture: true, passive: true });
  const round = (value: number) => Math.round(value * 10) / 10;
  const sample = () => {
    const scroller = document.querySelector<HTMLElement>(options.scroller);
    const view = scroller?.getBoundingClientRect();
    const running = document
      .getAnimations()
      .filter((animation) => animation.playState === "running" && animation.effect instanceof KeyframeEffect);
    const movers: Element[] = [];
    for (const animation of running) {
      const effect = animation.effect as KeyframeEffect;
      const target = effect.target;
      if (!target) continue;
      const keyframes = effect.getKeyframes();
      const properties = [
        ...new Set(
          keyframes.flatMap((frame) =>
            Object.keys(frame)
              .filter((name) => !["offset", "computedOffset", "easing", "composite"].includes(name))
              .map(camel),
          ),
        ),
      ];
      if (animation instanceof CSSTransition) properties.push(camel(animation.transitionProperty));
      const geometry = properties.filter((name) => GEOMETRY.test(name));
      if (!geometry.length) continue;
      const timing = effect.getComputedTiming();
      if (!Number.isFinite(Number(timing.endTime))) continue;
      movers.push(target);
      if (animIds.has(animation)) continue;
      animIds.set(animation, (nextAnim += 1));
      const own = effect.getTiming().easing ?? "linear";
      const easing =
        own !== "linear" ? own : (keyframes.find((frame) => frame.easing && frame.easing !== "linear")?.easing ?? own);
      const tracked = target.matches(selectorAll) ? keyOf(target) : undefined;
      animations.push({
        target: tracked ?? `${target.tagName.toLowerCase()}.${[...target.classList].slice(0, 2).join(".")}`,
        properties: geometry,
        duration: round(Number(timing.duration) || 0),
        easing,
        frame: frames.length,
      });
    }
    const els: MotionFrameRecord["els"] = {};
    const animated: string[] = [];
    for (const element of document.querySelectorAll<HTMLElement>(selectorAll)) {
      const box = element.getBoundingClientRect();
      if (box.height === 0 && box.width === 0) continue;
      const entry = entryOf(element)!;
      // Rows count while any part of them is in the scroller's view; the dock and composer always.
      if (entry.kind === "row" && view && (box.bottom <= view.top || box.top >= view.bottom)) continue;
      const key = keyOf(element);
      els[key] = [[round(box.left), round(box.top), round(box.width), round(box.height)], entry.kind];
      if (movers.some((mover) => mover === element || mover.contains(element))) animated.push(key);
    }
    frames.push({
      t: round(performance.now() - origin),
      scrollTop: round(scroller?.scrollTop ?? 0),
      scrollHeight: scroller?.scrollHeight ?? 0,
      clientHeight: scroller?.clientHeight ?? 0,
      els,
      touched: [...touched],
      animated,
      marks,
    });
    touched = new Set();
    marks = [];
  };
  const loop = () => {
    if (!recording) return;
    sample();
    requestAnimationFrame(loop);
  };
  window.__transcriptMotion = {
    start() {
      frames = [];
      animations = [];
      inputs = [];
      touched = new Set();
      marks = [];
      origin = performance.now();
      if (!recording) {
        recording = true;
        observer.observe(document.documentElement, {
          subtree: true,
          childList: true,
          characterData: true,
          attributes: true,
        });
        requestAnimationFrame(loop);
      }
    },
    stop() {
      recording = false;
      observer.disconnect();
      return { frames, animations, inputs };
    },
    mark(label: string) {
      if (!recording) return;
      marks.push(label);
      if (label.startsWith("input")) inputs.push(performance.now() - origin);
    },
    count: () => frames.length,
  };
}

export type MotionFlagKind = "move" | "resize" | "off-curve";
export type MotionFlag = {
  kind: MotionFlagKind;
  /** The element (a key) or, for `off-curve`, the animated target. */
  key: string;
  /** Its kind: row, composer, dock, fold-card. */
  of: string;
  frame: number;
  t: number;
  /** The largest delta (px), or the animation's length (ms) for `off-curve`. */
  px: number;
  /** The marks (steps) of this frame and the two before. */
  after: string[];
  /** Touched elements that changed size in the same frame: what pushed it (empty: nothing seen did). */
  cause: string[];
  detail?: string;
};

const normalize = (easing: string) =>
  easing
    .replace(/\s+/g, "")
    .replace(/^ease-out$/, "cubic-bezier(0,0,0.58,1)")
    .replace(/(\d*\.\d+|\d+)/g, (n) => String(Number(n)));
const HOUSE = new Set(HOUSE_EASINGS.map(normalize));

/** Whether an animation's easing and length are the house's. */
export function onHouseCurve(animation: Pick<AnimationSeen, "easing" | "duration">): boolean {
  return HOUSE.has(normalize(animation.easing)) && animation.duration <= HOUSE_MAX_MS + 0.5;
}

/** Every flag in `record`, in frame order. */
export function transcriptMoves(record: MotionRecord): MotionFlag[] {
  const flags: MotionFlag[] = [];
  const { frames } = record;
  const recentMarks = (index: number) =>
    frames.slice(Math.max(0, index - 2), index + 1).flatMap((frame) => frame.marks);
  for (let index = 1; index < frames.length; index += 1) {
    const was = frames[index - 1]!;
    const now = frames[index]!;
    const touched = new Set([...was.touched, ...now.touched]);
    const animated = new Set([...was.animated, ...now.animated]);
    // The reader's scroll: the rows ride it, so it is taken out of their move.
    const input = record.inputs.some((at) => at <= now.t && now.t - at <= INPUT_MS);
    const scrolled = input ? now.scrollTop - was.scrollTop : 0;
    const cause = Object.entries(now.els)
      .filter(([key, [box]]) => touched.has(key) && was.els[key] && Math.abs(box[3] - was.els[key]![0][3]) > STILL_PX)
      .map(
        ([key, [box]]) =>
          `${key} ${box[3] > was.els[key]![0][3] ? "+" : ""}${Math.round(box[3] - was.els[key]![0][3])}`,
      );
    for (const [key, [box, of]] of Object.entries(now.els)) {
      const before = was.els[key];
      if (!before || touched.has(key) || animated.has(key)) continue;
      const ride = of === "row" ? scrolled : 0;
      const [x, y, w, h] = box;
      const [x0, y0, w0, h0] = before[0];
      const dy = y - y0 + ride;
      const dx = x - x0;
      const moved = Math.max(Math.abs(dx), Math.abs(dy));
      const sized = Math.max(Math.abs(w - w0), Math.abs(h - h0));
      const base = { key, of, frame: index, t: now.t, after: recentMarks(index), cause };
      if (moved > STILL_PX)
        flags.push({
          ...base,
          kind: "move",
          px: Math.round(moved * 10) / 10,
          detail: `dx ${Math.round(dx)} dy ${Math.round(dy)}`,
        });
      if (sized > STILL_PX)
        flags.push({ ...base, kind: "resize", px: Math.round(sized * 10) / 10, detail: `${w0}x${h0} -> ${w}x${h}` });
    }
  }
  for (const animation of record.animations) {
    if (onHouseCurve(animation)) continue;
    const frame = frames[animation.frame];
    flags.push({
      kind: "off-curve",
      key: animation.target,
      of: animation.target.startsWith("row:") ? "row" : animation.target,
      frame: animation.frame,
      t: frame?.t ?? 0,
      px: animation.duration,
      after: recentMarks(animation.frame),
      cause: [],
      detail: `${animation.properties.join(",")} ${animation.duration} ms ${animation.easing}`,
    });
  }
  return flags.sort((a, b) => a.frame - b.frame);
}

/** The step a flag came after, as a class for the table: turn end, stream, steer, send, notice, ... */
export function stepClass(flag: Pick<MotionFlag, "after">): string {
  const labels = flag.after.join(" ");
  if (/turn_end|turn_result|status ready/.test(labels)) return "turn-end";
  if (/compaction/.test(labels)) return "compaction";
  if (/steer/.test(labels)) return "steer";
  if (/prompt:|send/.test(labels)) return "send";
  if (/incoming/.test(labels)) return "notice";
  if (/tool start|tool completed|tool failed/.test(labels)) return "tool";
  if (/assistant delta|thought delta/.test(labels)) return "stream";
  if (/input|reader/.test(labels)) return "scroll";
  if (/subagent|background/.test(labels)) return "subagent";
  return labels ? "other" : "no step";
}

/** Counts by kind, for a seed or a run. */
export function countFlags(flags: readonly MotionFlag[]) {
  const counts: Record<MotionFlagKind, number> = { move: 0, resize: 0, "off-curve": 0 };
  for (const flag of flags) counts[flag.kind] += 1;
  return counts;
}
