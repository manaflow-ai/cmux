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
// writing `style` from script is no touch: it is a move, and it is judged as one. An element whose inline
// `translate` or `transform` script writes on three or more frames running is a script animation (the
// follow chase, followChase.ts, draws the thread so): the elements it holds count as animated while it
// runs, and the run itself is judged (`off-curve` when it turns back, a bounce). A one-frame write (a
// placement jump) is no animation.
//
// The node side (`transcriptMoves`, pure) names, frame by frame:
// - `move`: an element no step touched (in this frame or the one before) and no animation moves, that is
//   drawn more than 1 px from where it was drawn the frame before. The reader's own scroll (input) is
//   taken out first: their wheel moves every row, and that is theirs.
// - `resize`: the same element's box more than 1 px taller, shorter, wider or narrower.
// - `off-curve`: a running animation that moves geometry (transform, translate, a height, a clip) on
//   another easing than the house's (motion/scale.generated.ts: the settle, the send curve, the ease-out,
//   the spring, the follow's arrival step) or longer than the scale's ceiling (MOTION_MS.large); or a
//   script animation that turns back on itself.
// - `offscreen-start`: an animation (any: a CSS transition, a CSS animation, WAAPI, a FLIP) started on a row
//   whose path (where it is drawn to where it lands; a container's: its rows') does not meet the view. A motion no one can see plays for no one; seen later, it is a
//   half-state (cmuxterm-hq docs/design/transcript-animation-rules.md, rule 1).
// - `scroll-start`: an animation started on a row while the reader scrolled (input in the last
//   SCROLL_START_MS and the view moved), with no press or key on that row and no new data for it: a row
//   that mounts, re-measures or is placed again as it scrolls into view draws in place (rules 2-4).
//   Leo, 2026-11-22: "i scroll down, some bullshit ABOVE folds...? and plays an animation!?"
// Each flag names what landed just before it (the step's marks) and what grew beside it in the same frame
// (its cause), so a table can say which steps make the jumps.
//
// The layout-motion contract (handbook undeclared-layout-move; cmux#48683) is the same idea for every
// surface, with declared moves; its judge is unmerged. This detector needs no declaration: in a transcript
// every move must either be the touched element's own, or ride an animation on the house curve.
import { MAIN_DOCK } from "../../src/agent-session/acpmux/composerSelectors";
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
/** Frames running on which script writes an element's translate before it counts as an animation. */
export const SCRIPT_RUN_FRAMES = 3;

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
  /** Elements whose inline translate or transform script wrote since the last frame: id -> [its y
   *  offset (px), the tracked keys it holds in view]. */
  driven?: Record<string, [y: number, keys: string[]]>;
};
/** Every animation that started inside the scroller, whatever it animates (the stray-motion judge). */
export type AnimationStart = {
  /** The tracked element holding the target (`row:ID`, or a fold copy's key), or `tag.class`. */
  target: string;
  /** `waapi` (Element.animate, a FLIP), `transition` or `css-animation`. */
  type: "waapi" | "transition" | "css-animation";
  /** The transition's property, the animation's name, or the keyframes' properties. */
  what: string;
  /** The span the motion covers against the view's top (see `startSpan`), and the view's height (px). */
  top: number;
  bottom: number;
  view: number;
  frame: number;
  t: number;
  /** The holder mounted before in this recording, left, and is drawn again (a virtualized remount). */
  remount?: boolean;
  /** The class of the animated element, when it is not the holder. */
  part?: string;
  /** Where an `Element.animate` was called (first frames of the stack). */
  stack?: string;
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
export type MotionRecord = {
  frames: MotionFrameRecord[];
  animations: AnimationSeen[];
  inputs: number[];
  /** Every animation start inside the scroller (older records have none). */
  starts?: AnimationStart[];
  /** Presses and keys, each with the tracked element it went to: [t, key]. */
  aimed?: [t: number, key: string][];
  /** When each row's data last came or changed, from the harness's steps (`rows(list)`): key -> t. */
  arrived?: Record<string, number>;
};

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
    { selector: MAIN_DOCK, kind: "dock", key: "dock" },
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
      /** The rows the chat has after a step (their ids), so a row's data arrival is known. */
      rows?(list: readonly (string | readonly [id: string, signature: string])[]): void;
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
  let starts: AnimationStart[] = [];
  let aimed: [number, string][] = [];
  let arrived: Record<string, number> = {};
  const signatures = new Map<string, string>();
  /** Keys drawn last frame, and every key drawn in this recording. */
  let drawnLast = new Set<string>();
  let drawnEver = new Set<string>();
  const startSeen = new WeakSet<Animation>();
  const stacks = new WeakMap<Animation, string>();
  const nativeAnimate = Element.prototype.animate;
  Element.prototype.animate = function (this: Element, ...args: Parameters<Element["animate"]>) {
    const animation = nativeAnimate.apply(this, args);
    if (recording) {
      const stack = new Error().stack
        ?.split("\n")
        .slice(2, 7)
        .map((line) => line.trim())
        .join(" | ");
      if (stack) stacks.set(animation, stack);
    }
    return animation;
  } as Element["animate"];
  let touched = new Set<string>();
  let marks: string[] = [];
  let styled = new Set<Element>();
  const driverIds = new WeakMap<Element, string>();
  const driverOf = (element: Element) => {
    let id = driverIds.get(element);
    if (!id) {
      id = element.matches(selectorAll)
        ? keyOf(element)
        : `${element.tagName.toLowerCase()}.${[...element.classList].slice(0, 2).join(".")}#${(nextId += 1)}`;
      driverIds.set(element, id);
    }
    return id;
  };
  const observer = new MutationObserver((list) => {
    if (!recording) return;
    for (const mutation of list) {
      if (mutation.type === "attributes" && mutation.attributeName === "style") {
        if (mutation.target instanceof Element) styled.add(mutation.target);
        continue;
      }
      const owner = holder(mutation.target);
      if (owner) touched.add(keyOf(owner));
      for (const node of mutation.addedNodes) {
        if (!(node instanceof Element)) continue;
        if (node.matches(selectorAll)) touched.add(keyOf(node));
        for (const inner of node.querySelectorAll(selectorAll)) touched.add(keyOf(inner));
      }
    }
  });
  const onInput = (event: Event) => {
    if (!recording) return;
    const at = performance.now() - origin;
    inputs.push(at);
    if (event.type === "wheel" || event.type === "touchstart") return;
    const target = event.type === "keydown" ? document.activeElement : (event.target as Element | null);
    const owner = target instanceof Element ? holder(target) : null;
    if (owner) aimed.push([at, keyOf(owner)]);
  };
  for (const kind of ["wheel", "keydown", "pointerdown", "touchstart"])
    addEventListener(kind, onInput, { capture: true, passive: true });
  /**
   * The span a starting motion covers, in the page's coordinates, for the `offscreen-start` rule: where
   * the moved boxes are drawn now and where they land, as one span (the rule tailGlide.ts `missesView`
   * applies before it starts a glide). Two cases the element's own drawn box misjudged
   * (transcript-fold-above-view-browser, run 45579324266):
   * - a row gliding up from just below the view with the tail it moves with (drawn 794..838 of 772,
   *   landing in it) is seen as it lands; only a path that misses the view plays for no one;
   * - a container whose rows are placed absolutely under it (`.acpmux-thread`: its own box is its 32 px of
   *   padding at the chat's top) moves its rows: its span is theirs, the mounted ones.
   */
  function startSpan(element: Element, box: DOMRect, rows: ArrayLike<Element>): { top: number; bottom: number } {
    let top = box.top;
    let bottom = box.bottom;
    if (rows.length) {
      top = Infinity;
      bottom = -Infinity;
      for (let index = 0; index < rows.length; index += 1) {
        const row = rows[index]!.getBoundingClientRect();
        if (row.width === 0 && row.height === 0) continue;
        top = Math.min(top, row.top);
        bottom = Math.max(bottom, row.bottom);
      }
      if (top > bottom) return { top: box.top, bottom: box.bottom };
    }
    // Where it lands: drawn less its own `translate` (the glide's offset, composite add; a transform is
    // not read: no transcript motion moves rows by one).
    const value = element.ownerDocument.defaultView?.getComputedStyle(element).translate ?? "";
    const y = value && value !== "none" ? Number.parseFloat(value.split(" ")[1] ?? "") : 0;
    if (Number.isFinite(y) && y !== 0) {
      top = Math.min(top, top - y);
      bottom = Math.max(bottom, bottom - y);
    }
    return { top, bottom };
  }

  const round = (value: number) => Math.round(value * 10) / 10;
  /** Every animation that started since the last frame inside the scroller (any property, any kind). */
  const sampleStarts = (scroller: HTMLElement | null, view: DOMRect | undefined) => {
    if (!scroller || !view) return;
    for (const animation of document.getAnimations()) {
      if (startSeen.has(animation)) continue;
      startSeen.add(animation);
      const effect = animation.effect;
      if (!(effect instanceof KeyframeEffect) || !effect.target) continue;
      const target = effect.target;
      if (!scroller.contains(target)) continue;
      const timing = effect.getComputedTiming();
      // An ambient loop (a spinner, a shimmer) and a zero-length step are no motion.
      if (timing.iterations === Infinity || !(Number(timing.activeDuration) > 0)) continue;
      // The running line's shimmer sweeps once per cadence (shimmerCadence.ts), only while seen: ambient.
      if (animation instanceof CSSAnimation && animation.animationName.startsWith("cmux-cadenced-shimmer")) continue;
      if (animation.playState === "finished") continue;
      const owner = target.matches(selectorAll) ? target : holder(target);
      const box = (owner ?? target).getBoundingClientRect();
      if (box.width === 0 && box.height === 0) continue;
      const span = startSpan(owner ?? target, box, owner ? [] : target.querySelectorAll(selectorAll));
      const key = owner
        ? keyOf(owner)
        : `${target.tagName.toLowerCase()}.${[...target.classList].slice(0, 2).join(".")}`;
      const type =
        animation instanceof CSSTransition
          ? "transition"
          : animation instanceof CSSAnimation
            ? "css-animation"
            : "waapi";
      const what =
        animation instanceof CSSTransition
          ? camel(animation.transitionProperty)
          : animation instanceof CSSAnimation
            ? animation.animationName
            : [
                ...new Set(
                  effect
                    .getKeyframes()
                    .flatMap((frame) =>
                      Object.keys(frame).filter(
                        (name) => !["offset", "computedOffset", "easing", "composite"].includes(name),
                      ),
                    )
                    .map(camel),
                ),
              ].join("+");
      const stack = stacks.get(animation);
      starts.push({
        target: key,
        type,
        what,
        top: round(span.top - view.top),
        bottom: round(span.bottom - view.top),
        view: round(view.height),
        frame: frames.length,
        t: round(performance.now() - origin),
        ...(owner && drawnEver.has(key) && !drawnLast.has(key) && { remount: true }),
        ...(owner &&
          owner !== target && { part: [...target.classList].slice(0, 2).join(".") || target.tagName.toLowerCase() }),
        ...(stack && { stack }),
      });
    }
  };
  const sample = () => {
    const scroller = document.querySelector<HTMLElement>(options.scroller);
    const view = scroller?.getBoundingClientRect();
    sampleStarts(scroller, view);
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
    const inView: [string, Element][] = [];
    const animated: string[] = [];
    const drawnNow = new Set<string>();
    for (const element of document.querySelectorAll<HTMLElement>(selectorAll)) {
      drawnNow.add(keyOf(element));
      const box = element.getBoundingClientRect();
      if (box.height === 0 && box.width === 0) continue;
      const entry = entryOf(element)!;
      // Rows count while any part of them is in the scroller's view; the dock and composer always.
      if (entry.kind === "row" && view && (box.bottom <= view.top || box.top >= view.bottom)) continue;
      const key = keyOf(element);
      inView.push([key, element]);
      els[key] = [[round(box.left), round(box.top), round(box.width), round(box.height)], entry.kind];
      if (movers.some((mover) => mover === element || mover.contains(element))) animated.push(key);
    }
    // Script's own moves: an inline translate or transform written this frame, and what it holds.
    const driven: NonNullable<MotionFrameRecord["driven"]> = {};
    for (const element of styled) {
      const style = (element as HTMLElement).style;
      if (!style || (!style.translate && !style.transform && !driverIds.has(element))) continue;
      const y = Number.parseFloat((style.translate || "0 0").split(" ")[1] ?? "0") || 0;
      const call = /translate(Y|3d)?\(([^)]*)\)/.exec(style.transform);
      const args = call?.[2]?.split(",") ?? [];
      const ty = Number.parseFloat((call?.[1] === "Y" ? args[0] : args[1]) ?? "0") || 0;
      const keys = inView.filter(([, held]) => held === element || element.contains(held)).map(([key]) => key);
      driven[driverOf(element)] = [round(y + ty), keys];
    }
    styled = new Set();
    for (const key of drawnNow) drawnEver.add(key);
    drawnLast = drawnNow;
    frames.push({
      t: round(performance.now() - origin),
      scrollTop: round(scroller?.scrollTop ?? 0),
      scrollHeight: scroller?.scrollHeight ?? 0,
      clientHeight: scroller?.clientHeight ?? 0,
      els,
      touched: [...touched],
      animated,
      marks,
      ...(Object.keys(driven).length && { driven }),
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
      starts = [];
      aimed = [];
      arrived = {};
      signatures.clear();
      touched = new Set();
      marks = [];
      origin = performance.now();
      // What is drawn now was drawn before the recording: a row of it that leaves and comes back remounts.
      drawnEver = new Set([...document.querySelectorAll(selectorAll)].map(keyOf));
      drawnLast = new Set(drawnEver);
      // Animations already running started before the recording: they are not this recording's starts.
      for (const animation of document.getAnimations()) startSeen.add(animation);
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
      return { frames, animations, inputs, starts, aimed, arrived };
    },
    mark(label: string) {
      if (!recording) return;
      marks.push(label);
      if (label.startsWith("input")) inputs.push(performance.now() - origin);
    },
    rows(list: readonly (string | readonly [id: string, signature: string])[]) {
      if (!recording) return;
      const at = round(performance.now() - origin);
      for (const entry of list) {
        const [id, signature] = typeof entry === "string" ? [entry, ""] : entry;
        const key = `row:${id}`;
        // New data is a new row or a row whose content changed (a Thinking line's words, a tool done).
        if (key in arrived && signatures.get(key) === signature) continue;
        arrived[key] = at;
        signatures.set(key, signature);
      }
    },
    count: () => frames.length,
  };
}

export type MotionFlagKind = "move" | "resize" | "off-curve" | "offscreen-start" | "scroll-start";
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
    .replace(/^ease-out$/, MOTION_EASE_OUT.replace(/\s+/g, ""))
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
  const { animatedAt, bounces } = scriptRuns(frames);
  for (const bounce of bounces)
    flags.push({
      kind: "off-curve",
      key: bounce.driver,
      of: "script",
      frame: bounce.frame,
      t: frames[bounce.frame]?.t ?? 0,
      px: bounce.px,
      after: recentMarks(bounce.frame),
      cause: [],
      detail: `script translate run of ${bounce.ms} ms turned back ${bounce.px} px (${bounce.row})`,
    });
  for (let index = 1; index < frames.length; index += 1) {
    const was = frames[index - 1]!;
    const now = frames[index]!;
    const touched = new Set([...was.touched, ...now.touched]);
    const animated = new Set([...was.animated, ...now.animated, ...(animatedAt.get(index) ?? [])]);
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
  flags.push(...strayStarts(record));
  return flags.sort((a, b) => a.frame - b.frame);
}

/** The reader scrolled this recently (ms; input, and the view moved): a start then is the scroll's. */
export const SCROLL_START_MS = 200;
/** A press or key on a row this recently makes its motion the reader's (ms). */
export const AIMED_MS = 1_000;
/** A row whose data came this recently is new: its entrance is a change the reader is looking at (ms). */
export const FRESH_MS = 600;
/** A box this far past the view's edge (px) still counts as in it. */
const EDGE_PX = 1;

/** The starts that break docs/design/transcript-animation-rules.md: `offscreen-start` and `scroll-start`. */
export function strayStarts(record: MotionRecord): MotionFlag[] {
  const { frames } = record;
  const flags: MotionFlag[] = [];
  const recentMarks = (index: number) =>
    frames.slice(Math.max(0, index - 2), index + 1).flatMap((frame) => frame.marks);
  // When the view moved under the reader's input: a frame whose offset changed within INPUT_MS of input.
  const scrolledAt: number[] = [];
  for (let index = 1; index < frames.length; index += 1) {
    const now = frames[index]!;
    if (Math.abs(now.scrollTop - frames[index - 1]!.scrollTop) <= 0.5) continue;
    if (record.inputs.some((at) => at <= now.t && now.t - at <= INPUT_MS)) scrolledAt.push(now.t);
  }
  for (const start of record.starts ?? []) {
    const base = {
      key: start.target,
      of: start.target.startsWith("row:") ? "row" : start.target,
      frame: start.frame,
      t: start.t,
      px: Math.round(start.top),
      after: recentMarks(start.frame),
      cause: [],
      detail: `${start.type} ${start.what}${start.part ? ` on .${start.part}` : ""} at ${start.top}..${start.bottom} of ${start.view}${start.remount ? ", remount" : ""}${start.stack ? ` @ ${start.stack}` : ""}`,
    };
    if (start.bottom <= EDGE_PX || start.top >= start.view - EDGE_PX) {
      flags.push({ ...base, kind: "offscreen-start" });
      continue;
    }
    const scrolling = scrolledAt.some((at) => at <= start.t + 17 && start.t - at <= SCROLL_START_MS);
    if (!scrolling) continue;
    const aimed = (record.aimed ?? []).some(
      ([at, key]) => key === start.target && start.t - at <= AIMED_MS && at <= start.t,
    );
    const came = record.arrived?.[start.target];
    const fresh = came !== undefined && start.t - came <= FRESH_MS;
    if (!aimed && !fresh) flags.push({ ...base, kind: "scroll-start" });
  }
  return flags;
}

/** Script animations: each element script wrote a translate on for SCRIPT_RUN_FRAMES frames running (a
 *  gap of one frame does not end a run). What it holds counts as animated from the frame before the run to
 *  the frame after; a run whose held row's drawn top turns back by more than STILL_PX is a bounce. */
export function scriptRuns(frames: readonly MotionFrameRecord[]) {
  const seen = new Map<string, number[]>();
  frames.forEach((frame, index) => {
    for (const driver of Object.keys(frame.driven ?? {})) seen.set(driver, [...(seen.get(driver) ?? []), index]);
  });
  const animatedAt = new Map<number, Set<string>>();
  const bounces: { driver: string; frame: number; px: number; ms: number; row: string }[] = [];
  for (const [driver, indices] of seen) {
    const runs: number[][] = [];
    for (const index of indices) {
      const run = runs.at(-1);
      if (run && index - run.at(-1)! <= 2) run.push(index);
      else runs.push([index]);
    }
    for (const run of runs) {
      if (run.length < SCRIPT_RUN_FRAMES) continue;
      const first = run[0]!;
      const last = run.at(-1)!;
      const keys = new Set(run.flatMap((index) => frames[index]!.driven![driver]![1]));
      for (let index = Math.max(0, first - 1); index <= Math.min(frames.length - 1, last + 1); index += 1) {
        const set = animatedAt.get(index) ?? new Set<string>();
        for (const key of keys) set.add(key);
        animatedAt.set(index, set);
      }
      // The drawn top of a row the run holds throughout, frame by frame: it must go one way.
      const row = [...keys].find((key) => run.every((index) => frames[index]!.els[key]));
      if (!row) continue;
      let direction = 0;
      let turn = 0;
      let at = first;
      for (let i = 1; i < run.length; i += 1) {
        const delta = frames[run[i]!]!.els[row]![0][1] - frames[run[i - 1]!]!.els[row]![0][1];
        if (Math.abs(delta) <= STILL_PX) continue;
        const sign = Math.sign(delta);
        if (direction && sign !== direction && Math.abs(delta) > turn) {
          turn = Math.abs(delta);
          at = run[i]!;
        }
        direction = sign;
      }
      if (turn > STILL_PX)
        bounces.push({
          driver,
          frame: at,
          px: Math.round(turn * 10) / 10,
          ms: Math.round(frames[last]!.t - frames[first]!.t),
          row,
        });
    }
  }
  return { animatedAt, bounces };
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
  const counts: Record<MotionFlagKind, number> = {
    move: 0,
    resize: 0,
    "off-curve": 0,
    "offscreen-start": 0,
    "scroll-start": 0,
  };
  for (const flag of flags) counts[flag.kind] += 1;
  return counts;
}
