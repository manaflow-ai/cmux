// The motion contract: the "mathematical way" to say what is wrong with a transition (Leo,
// 2026-11-11: "Any and all animations can be good if only they meet those prerequisites ... It's not
// fast enough and it's not together enough ... There should be, like, mathematical ways to determine
// what is wrong with ours").
//
// A recorder (page side, `installMotionRecorder`) reads every painted frame (support/paintedFrames.ts):
// each tracked element's drawn box (getBoundingClientRect, so a scroll, a `translate` and a running
// Web Animation all count), the scroller's offset, every finite animation the page runs (CSS
// animations, CSS transitions and Web Animations, through `document.getAnimations()`, with the
// properties they animate), and the longest uninterrupted main-thread block in the frame (a posted
// message heartbeat: a gap between two beats is a task or a rendering update that held the thread).
// `analyzeMotion` (pure, node side) turns one transition's frames into the four numbers the contract
// bounds:
//
// (a) speed: from the frame a thing starts moving to the frame it rests, at most MAX_SETTLE_MS;
// (b) cadence: frame intervals p95 at most a 120 Hz slot, none over two slots, and no main-thread
//     block in the transition over a slot (a block over a slot is a frame a 120 Hz display drops);
// (c) togetherness: every element that moves in one transition starts in the same frame and rests in
//     the same frame (skew 0 frames), and the max difference between their normalized progress in any
//     frame (the velocity mismatch: two elements on one curve have the same progress every frame);
// (d) once: nothing moves twice: after an element rests it does not move again in the transition (a
//     pop or a second correction), and it never reverses direction while it moves; a row that comes in
//     reaches its final height within MAX_GROW_FRAMES of its first drawn frame (no slow growth).
//
// Stop condition: the recorder runs only between `start` and `stop` (one after-paint read a frame and
// one heartbeat chain while it records).
import type { Page } from "playwright";

/// One 120 Hz slot (ms).
export const SLOT_MS = 1000 / 120;
/// (a) The most a transition takes from its first moving frame to its rest (ms).
export const MAX_SETTLE_MS = 150;
/// (d) A row that comes in has its final height within this many drawn frames of its first one.
export const MAX_GROW_FRAMES = 2;
/// A move under this (px) in a frame is rounding, not motion.
export const STILL_PX = 0.5;
/// Properties a compositor can animate without layout or paint of the rows.
export const COMPOSITOR_PROPERTIES = new Set(["transform", "translate", "scale", "rotate", "opacity", "offset"]);

export type ElementSample = { top: number; height: number; opacity: number };
export type MotionFrame = {
  /// The frame's time (rAF), ms.
  t: number;
  /// Tracked elements drawn this frame (in the scroller's view or in the bottom stack), by key.
  els: Record<string, ElementSample>;
  scrollTop: number;
  /// The scroller's distance from its end (px).
  fromEnd: number;
  /// The longest main-thread block since the last frame (ms).
  block: number;
  /// Script markers set this frame (`__motion.mark(name)`).
  marks: string[];
  /// VEHICLE, never merges: what draws the live line in this frame.
  probe?: string;
};
export type AnimationRecord = {
  /// What it animates: a tracked key, or a selector-ish description.
  target: string;
  kind: string;
  duration: number;
  easing: string;
  properties: string[];
  /// The frame it was first seen running in (index into the frames).
  frame: number;
};
export type MotionRecording = { frames: MotionFrame[]; animations: AnimationRecord[] };

declare global {
  interface Window {
    __motion: {
      start(): void;
      stop(): MotionRecording;
      mark(name: string): void;
    };
  }
}

/// The page side: defines `window.__motion`. Runs in the page, so it closes over nothing. Tracked:
/// every transcript row (`row:<id>`), the composer's card (`composer`), the queue list (`queue`) and
/// each queued prompt's row (`queued:<id>`), the thinking/live line (`live`).
export function defineMotionRecorder() {
  if ((window as { __motion?: unknown }).__motion) return;
  let recording = false;
  let frames: MotionFrame[] = [];
  let animations: AnimationRecord[] = [];
  let seen = new WeakSet<Animation>();
  let marks: string[] = [];
  let longest = 0;
  let lastBeat = 0;
  const beat = new MessageChannel();
  beat.port1.onmessage = () => {
    if (!recording) return;
    // The wall clock: a page on the frames' own clock (browser/frameClock.ts) has its
    // `performance.now` on that clock, which never shows a block.
    const now = Date.now();
    longest = Math.max(longest, now - lastBeat);
    lastBeat = now;
    beat.port2.postMessage(0);
  };
  const keyOf = (element: Element | null): string => {
    if (!element) return "?";
    const row = element.closest<HTMLElement>(".acpmux-row[data-row-id]");
    if (row) return `row:${row.dataset.rowId}`;
    const queued = element.closest<HTMLElement>(".acpmux-queued[data-prompt-id]");
    if (queued) return `queued:${queued.dataset.promptId}`;
    if (element.closest(".acpmux-composer-queue")) return "queue";
    if (element.closest(".acpmux-composer-box")) return "composer";
    if (element.matches(".acpmux-thread")) return "thread";
    const name = element.className && typeof element.className === "string" ? element.className.split(" ")[0] : "";
    return `${element.tagName.toLowerCase()}${name ? `.${name}` : ""}`;
  };
  const finite = (animation: Animation) =>
    Number.isFinite(animation.effect?.getComputedTiming().endTime ?? Number.POSITIVE_INFINITY);
  const read = (t: number) => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
    if (!scroller) return;
    const view = scroller.getBoundingClientRect();
    const els: Record<string, ElementSample> = {};
    const sample = (key: string, element: HTMLElement, inView = true) => {
      const box = element.getBoundingClientRect();
      if (box.height === 0 || !inView) return;
      els[key] = { top: box.top, height: box.height, opacity: Number.parseFloat(getComputedStyle(element).opacity) };
    };
    for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
      const box = row.getBoundingClientRect();
      sample(`row:${row.dataset.rowId}`, row, box.bottom > view.top && box.top < view.bottom);
    }
    const card = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-dock .acpmux-composer-box");
    if (card) sample("composer", card);
    const queue = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-dock .acpmux-composer-queue");
    if (queue) sample("queue", queue);
    for (const queued of document.querySelectorAll<HTMLElement>(
      ".acpmux-main > .acpmux-dock .acpmux-queued[data-prompt-id]",
    ))
      sample(`queued:${queued.dataset.promptId}`, queued);
    for (const animation of document.getAnimations()) {
      if (seen.has(animation) || animation.playState !== "running" || !finite(animation)) continue;
      seen.add(animation);
      const effect = animation.effect as KeyframeEffect | null;
      const timing = effect?.getComputedTiming();
      let properties: string[] = [];
      try {
        properties = [
          ...new Set(
            (effect?.getKeyframes() ?? []).flatMap((frame) =>
              Object.keys(frame).filter((key) => !["offset", "computedOffset", "easing", "composite"].includes(key)),
            ),
          ),
        ];
      } catch {
        properties = [];
      }
      if ("transitionProperty" in animation) properties = [String((animation as CSSTransition).transitionProperty)];
      animations.push({
        target: keyOf((effect?.target as Element | null) ?? null),
        kind: animation.constructor.name,
        duration: Number(timing?.duration ?? 0),
        easing: effect?.getTiming().easing ?? "",
        properties,
        frame: frames.length,
      });
    }
    // VEHICLE, never merges: the thread's offset, the pin, the live line's own translate, its box,
    // its words, its padding, each animation on it and on the row over it.
    const probe = (() => {
      const thread = scroller.querySelector<HTMLElement>(".acpmux-thread");
      const live = scroller.querySelector<HTMLElement>('.acpmux-row[data-row-id="thinking-live"]');
      const plays = (element: Element | null | undefined) =>
        (element?.getAnimations() ?? [])
          .map((animation) => {
            const effect = animation.effect as KeyframeEffect | null;
            let names = "?";
            let ends = "";
            try {
              const keyframes = effect?.getKeyframes() ?? [];
              names = [
                ...new Set(
                  keyframes.flatMap((frame) =>
                    Object.keys(frame).filter(
                      (key) => !["offset", "computedOffset", "easing", "composite"].includes(key),
                    ),
                  ),
                ),
              ].join("+");
              const first = keyframes[0] as Record<string, unknown> | undefined;
              const last = keyframes.at(-1) as Record<string, unknown> | undefined;
              if (first && "translate" in first) ends = `[${String(first.translate)}>${String(last?.translate)}]`;
            } catch {
              names = "?";
            }
            return `${names}${ends}:${animation.playState}@${Number(animation.currentTime ?? -1).toFixed(0)}/${Number(effect?.getComputedTiming().duration ?? 0).toFixed(0)}`;
          })
          .join(",") || "-";
      if (!thread) return "no-thread";
      const over = live?.previousElementSibling as HTMLElement | null | undefined;
      const words = live?.querySelector<HTMLElement>(".cv-worked--live");
      const style = live ? getComputedStyle(live) : undefined;
      return [
        `tx=${thread.style.translate || "-"}`,
        `pin=${thread.hasAttribute("data-pin-live") ? 1 : 0}`,
        `end=${thread.hasAttribute("data-turn-end-folding") ? 1 : 0}`,
        `lt=${live?.style.translate || "-"}`,
        `lct=${style?.translate ?? "-"}`,
        `ltop=${live ? live.offsetTop : "-"}`,
        `lh=${live ? live.offsetHeight : "-"}`,
        `lpad=${style?.paddingTop ?? "-"}/${style?.marginTop ?? "-"}`,
        `words=${words ? words.getBoundingClientRect().top.toFixed(2) : "-"}`,
        `la=${plays(live)}`,
        `over=${over?.dataset.rowId ?? "-"}`,
        `oclip=${over?.style.clipPath || "-"}`,
        `oa=${plays(over)}`,
        `ta=${plays(thread)}`,
        `sh=${scroller.scrollHeight}`,
        `gp=${thread.dataset.glidePasses ?? "-"}`,
        `rows=${[...thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row[data-row-id]")]
          .slice(-6)
          .map((row) => `${(row.dataset.rowId ?? "").slice(0, 14)}:${getComputedStyle(row).translate}:${plays(row)}`)
          .join(";")}`,
      ].join(" ");
    })();
    frames.push({
      t,
      els,
      scrollTop: scroller.scrollTop,
      fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
      block: longest,
      marks,
      probe,
    });
    longest = 0;
    marks = [];
  };
  let stopRead: (() => void) | undefined;
  window.__motion = {
    start() {
      frames = [];
      animations = [];
      seen = new WeakSet();
      marks = [];
      longest = 0;
      recording = true;
      lastBeat = Date.now();
      beat.port2.postMessage(0);
      stopRead = window.cmuxAfterPaint((frame) => {
        if (recording) read(frame);
        return recording;
      });
    },
    stop() {
      recording = false;
      stopRead?.();
      return { frames, animations };
    },
    mark(name) {
      marks.push(name);
    },
  };
}

/// Defines the recorder in `page` (after installPaintedFrames).
export async function installMotionRecorder(page: Page) {
  await page.addInitScript(defineMotionRecorder);
  await page.evaluate(defineMotionRecorder);
}

const pct = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]! : 0;
};
const r2 = (value: number) => Math.round(value * 100) / 100;

/// One element's motion in a transition: the frames it moved in, as runs (a run ends at the first
/// still frame).
export type ElementMotion = {
  key: string;
  /// Index of the frame before its first move (its start), and of its last moving frame (its rest).
  start: number;
  end: number;
  /// Total travel and net displacement (px).
  travel: number;
  net: number;
  /// Separate runs of motion (more than one: it moved, rested, moved again).
  runs: number;
  /// Times it reversed direction while moving.
  reversals: number;
  /// For a row that came in during the transition: drawn frames until its height was final.
  growFrames: number;
  /// It left the view (scrolled out, unmounted) while it moved: its end is not the transition's.
  left: boolean;
};

export type MotionContractReport = {
  frames: number;
  /// (a) First move to rest of the whole transition (ms), and the slowest element's.
  settleMs: number;
  slowest: string;
  /// (b) Frame cadence.
  intervalP95: number;
  intervalMax: number;
  /// 120 Hz slots no frame was drawn in.
  dropped: number;
  blockP95: number;
  blockMax: number;
  /// (c) Start and end skew across the moving elements (frames), and the max progress mismatch (0..1).
  startSkew: number;
  endSkew: number;
  velocityMismatch: number;
  /// (d) Elements that moved twice or reversed, and rows that grew over more than MAX_GROW_FRAMES.
  movedTwice: string[];
  reversed: string[];
  slowGrowth: string[];
  /// Animations of layout properties (not compositor-only), by target and property.
  layoutAnimations: string[];
  /// Per element.
  elements: ElementMotion[];
};

/// Analyzes the frames `[from, to)` of a recording as one transition. `track`: which keys count
/// (default every key); `intervals`: the frame intervals to bound, when the caller measured drawn
/// frames itself (frames120's), else the frames' own rAF intervals.
export function analyzeMotion(
  recording: MotionRecording,
  {
    from = 0,
    to = recording.frames.length,
    track = () => true,
    intervals,
    dropped,
  }: {
    from?: number;
    to?: number;
    track?: (key: string) => boolean;
    intervals?: number[];
    dropped?: number;
  } = {},
): MotionContractReport {
  const frames = recording.frames.slice(from, to);
  const keys = new Set<string>();
  for (const frame of frames) for (const key of Object.keys(frame.els)) if (track(key)) keys.add(key);
  const firstPresent = new Map<string, number>();
  frames.forEach((frame, index) => {
    for (const key of Object.keys(frame.els)) if (!firstPresent.has(key)) firstPresent.set(key, index);
  });
  const elements: ElementMotion[] = [];
  const lastPresent = new Map<string, number>();
  frames.forEach((frame, index) => {
    for (const key of Object.keys(frame.els)) lastPresent.set(key, index);
  });
  for (const key of keys) {
    // `start`: the first frame that draws it moved (or, for a row that came during the transition and
    // then moves, the frame it came in); `end`: the last frame that draws it moving.
    let start = -1;
    let end = -1;
    let runs = 0;
    let moving = false;
    let travel = 0;
    let net = 0;
    let reversals = 0;
    let direction = 0;
    for (let index = 1; index < frames.length; index += 1) {
      const before = frames[index - 1]!.els[key];
      const now = frames[index]!.els[key];
      if (!before || !now) {
        moving = false;
        continue;
      }
      const dy = now.top - before.top;
      if (Math.abs(dy) > STILL_PX) {
        if (!moving) {
          runs += 1;
          if (start < 0) start = index;
        }
        moving = true;
        end = index;
        travel += Math.abs(dy);
        net += dy;
        const sign = Math.sign(dy);
        if (direction !== 0 && sign !== direction) reversals += 1;
        direction = sign;
      } else {
        moving = false;
        direction = 0;
      }
    }
    const came = firstPresent.get(key) ?? 0;
    // A row that came drawn where it moves from: its motion starts in the frame it came in.
    if (came > 0 && start === came + 1) start = came;
    // A row that scrolled out of view (or unmounted) while it moved: its motion goes on unseen, so its
    // end says nothing about when the transition rests.
    const left = (lastPresent.get(key) ?? frames.length - 1) < frames.length - 1 && end >= (lastPresent.get(key) ?? 0);
    // A row that came in during the window: frames from its first drawn frame until its height is final.
    let growFrames = 0;
    if (came > 0) {
      let last = came;
      const final = frames.at(-1)?.els[key]?.height;
      if (final !== undefined)
        for (let index = came; index < frames.length; index += 1) {
          const height = frames[index]!.els[key]?.height;
          if (height !== undefined && Math.abs(height - final) > STILL_PX) last = index + 1;
        }
      growFrames = last - came;
    }
    if (runs > 0 || growFrames > MAX_GROW_FRAMES)
      elements.push({ key, start, end, travel: r2(travel), net: r2(net), runs, reversals, growFrames, left });
  }
  const moved = elements.filter((element) => element.runs > 0);
  /// The elements whose start and end the transition's skew reads: those that stayed in view.
  const seen = moved.filter((element) => !element.left);
  const t = (index: number) => frames[Math.max(0, Math.min(frames.length - 1, index))]?.t ?? 0;
  const starts = moved.map((element) => element.start);
  const ends = seen.map((element) => element.end);
  const first = starts.length ? Math.min(...starts) : 0;
  const last = ends.length ? Math.max(...ends) : 0;
  let slowest = "";
  let slowestMs = 0;
  for (const element of seen) {
    const ms = t(element.end) - t(Math.max(0, element.start - 1));
    if (ms > slowestMs) {
      slowestMs = ms;
      slowest = element.key;
    }
  }
  // Progress mismatch: elements that moved one way more than 2 px and stayed in view, over the frames
  // all of them are drawn in (from the latest of their first drawn frames to the transition's rest),
  // each normalized over that window: one transform, or one curve, is 0 every frame.
  let velocityMismatch = 0;
  const rising = seen.filter((element) => element.runs === 1 && Math.abs(element.net) > 2);
  if (rising.length > 1) {
    const from = Math.max(first - 1, ...rising.map((element) => firstPresent.get(element.key) ?? 0));
    const base = rising.map((element) => frames[from]?.els[element.key]?.top);
    const end = rising.map((element) => frames[last]?.els[element.key]?.top);
    const span = rising.map((_, i) => (end[i] ?? 0) - (base[i] ?? 0));
    if (rising.every((_, i) => base[i] !== undefined && end[i] !== undefined && Math.abs(span[i]!) > 2))
      for (let index = from; index <= last; index += 1) {
        const progress = rising.map((element, i) => {
          const now = frames[index]?.els[element.key]?.top;
          return now === undefined ? 1 : Math.min(1, Math.max(0, (now - base[i]!) / span[i]!));
        });
        velocityMismatch = Math.max(velocityMismatch, Math.max(...progress) - Math.min(...progress));
      }
  }
  const ownIntervals = frames.slice(1).map((frame, index) => frame.t - frames[index]!.t);
  const spans = intervals ?? ownIntervals;
  const blocks = frames.map((frame) => frame.block);
  const range = (frame: number) => frame >= from && frame < to;
  const layoutAnimations = recording.animations
    .filter((animation) => range(animation.frame))
    .flatMap((animation) =>
      animation.properties
        .filter((property) => !COMPOSITOR_PROPERTIES.has(property))
        .map((property) => `${animation.target} ${property} ${Math.round(animation.duration)}ms`),
    );
  return {
    frames: frames.length,
    settleMs: r2(moved.length ? t(last) - t(Math.max(0, first - 1)) : 0),
    slowest,
    intervalP95: r2(pct(spans, 0.95)),
    intervalMax: r2(Math.max(0, ...spans)),
    dropped: dropped ?? spans.reduce((sum, span) => sum + Math.max(0, Math.round(span / SLOT_MS) - 1), 0),
    blockP95: r2(pct(blocks, 0.95)),
    blockMax: r2(Math.max(0, ...blocks)),
    startSkew: starts.length ? Math.max(...starts) - first : 0,
    endSkew: ends.length ? last - Math.min(...ends) : 0,
    velocityMismatch: r2(velocityMismatch),
    movedTwice: moved.filter((element) => element.runs > 1).map((element) => element.key),
    reversed: moved.filter((element) => element.reversals > 0).map((element) => element.key),
    slowGrowth: elements.filter((element) => element.growFrames > MAX_GROW_FRAMES).map((element) => element.key),
    layoutAnimations: [...new Set(layoutAnimations)],
    elements,
  };
}

/// The contract's verdicts for a report, by letter: an empty list passes.
export function contractFailures(
  report: MotionContractReport,
  { cadence = true }: { cadence?: boolean } = {},
): string[] {
  const out: string[] = [];
  if (report.settleMs > MAX_SETTLE_MS)
    out.push(`(a) settles in ${report.settleMs} ms (${report.slowest}) > ${MAX_SETTLE_MS}`);
  if (cadence) {
    if (report.intervalP95 > SLOT_MS + 0.05) out.push(`(b) frame interval p95 ${report.intervalP95} ms > 8.33`);
    if (report.intervalMax > 2 * SLOT_MS + 0.05) out.push(`(b) a frame interval of ${report.intervalMax} ms > 16.7`);
    if (report.blockMax > 2 * SLOT_MS) out.push(`(b) a main-thread block of ${report.blockMax} ms > 16.7`);
  }
  if (report.startSkew > 0 || report.endSkew > 0)
    out.push(`(c) start skew ${report.startSkew} / end skew ${report.endSkew} frames`);
  if (report.movedTwice.length) out.push(`(d) moved twice: ${report.movedTwice.join(", ")}`);
  if (report.reversed.length) out.push(`(d) reversed: ${report.reversed.join(", ")}`);
  if (report.slowGrowth.length) out.push(`(d) slow growth: ${report.slowGrowth.join(", ")}`);
  return out;
}
