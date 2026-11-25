// Box shift: layout shift measured from element boxes, frame by frame (Leo, 2026-11-01: "how about
// like the apparatuses for improving ui verification? let's examine what we can do better for our
// workflows"). The browser's own layout-shift entries (CLS) miss two things the stage must catch:
//   - a move that scrolling made: Chromium subtracts a scroller's scroll delta, so a bottom-pinned
//     transcript that scrolls its rows up when a tool call at the bottom expands reports no shift;
//   - motion outside Chromium: WebKit has no layout-shift entries at all.
// So the stage also samples the boxes of the rows a person reads (`TRACK_SELECTOR`, plus the entry's
// anchors) on every frame, in viewport coordinates, and scores their moves the way CLS does: per
// frame, the moved boxes' share of the viewport times the largest move's share of its longer side.
//
// What does not count, so a correct page scores 0:
//   - a box that has not yet held still for `REST_FRAMES` frames: an entrance animation, a row
//     still mounting. Once it rested, any later move counts (the composer gap that jumps on load).
//     A box a keyframe animation is moving (its own or an ancestor's, `animating`) has not rested
//     either: on a loaded runner an entrance can hold its first frame for a few frames before it
//     plays (the file search palette's ui-enter rise read as a 2.5 px shift, #40937);
//     A step starts on a settled page, so its first frame's boxes have rested (`restedAtStart`);
//   - the step's target, its ancestors and descendants (the tool row that expands), and while that
//     row opens at the very bottom (`BOTTOM_FOLD`), everything inside it: it rises as one;
//   - a box after the target in document order that moves straight down: the expansion pushes it;
//   - a box before the target that moves straight up while the target's transcript row opens at the
//     very bottom (`BOTTOM_FOLD`, `data-bottom-stack-fold`, set by the transcript for the length of
//     that fold): there the opening pushes the text above up by design (Leo, 2026-11-02: "YOU
//     EXPAND UP WHILE YOUR SCCROLL IS AT THE VERY BOTTOM AKA YOU ... PUSH THE TEXT UP VISUALLY
//     INSTEAD OF EXPANDING DOWN LIKE USUAL / JUST THAT CASE", #32644). Anywhere else a row rising is still a shift;
//   - a box's first move after a resize (`firstMoveFree`): the new width lays it out once; a second
//     move is the bounce a sidebar toggle must not have;
//   - moves under half a CSS px (layout rounding), and boxes outside the viewport.
// The pure scoring is here (unit tested); `startBoxTracker` samples the live page. The tracker also
// judges the same frames for the follow (followJudge.ts): a move other than the one translation the
// transcript rows share.
import { judgeFollowFrames, type FollowJudgement } from "./followJudge";

import {
  MEDIA_SELECTOR,
  bottomFoldOf,
  sampleBoxes,
  targetList,
  type Box,
  type BoxFrame,
  type StepTargets,
} from "../layout/boxSample";
import { openDeclarations } from "../layout/motionContract";
import { judgeMotion, type JudgeFrame, type MotionVerdict } from "../layout/motionJudge";

export {
  BOTTOM_FOLD,
  PIN_LIVE,
  TRACK_SELECTOR,
  TURN_END_FOLDING,
  bottomFoldOf,
  insetCrop,
  sampleBoxes,
  shownBox,
} from "../layout/boxSample";
export type { Box, BoxFrame, BoxSample, StepTargets } from "../layout/boxSample";

export type BoxMove = { label: string; frame: number; dx: number; dy: number };
export type BoxShift = { score: number; moves: BoxMove[]; follow?: FollowJudgement; motion?: MotionVerdict };

/** Frames a box must hold still before its moves count. */
export const REST_FRAMES = 2;
/** Moves under this many CSS px are layout rounding. */
export const MOVE_SLACK = 0.5;
/** Moves listed in a report; the score still counts every one. */
const MAX_MOVES = 24;
const area = (box: Box) => Math.max(0, box.width) * Math.max(0, box.height);

function clip(box: Box, viewport: { width: number; height: number }): Box {
  const x = Math.max(0, box.x);
  const y = Math.max(0, box.y);
  return {
    x,
    y,
    width: Math.min(viewport.width, box.x + box.width) - x,
    height: Math.min(viewport.height, box.y + box.height) - y,
  };
}

function union(a: Box, b: Box): Box {
  const x = Math.min(a.x, b.x);
  const y = Math.min(a.y, b.y);
  return {
    x,
    y,
    width: Math.max(a.x + a.width, b.x + b.width) - x,
    height: Math.max(a.y + a.height, b.y + b.height) - y,
  };
}

/** The CLS-style score of a run of frames (see the header for what is exempt). */
export function scoreBoxFrames(
  frames: BoxFrame[],
  viewport: { width: number; height: number },
  options: { firstMoveFree?: boolean; restedAtStart?: boolean } = {},
): BoxShift {
  const still = new Map<number, number>();
  // A step starts on a page that has been still: its boxes have rested already.
  if (options.restedAtStart) for (const id of frames[0]?.keys() ?? []) still.set(id, REST_FRAMES);
  const freeUsed = new Set<number>();
  const moves: BoxMove[] = [];
  let score = 0;
  const longer = Math.max(viewport.width, viewport.height, 1);
  const viewportArea = Math.max(1, viewport.width * viewport.height);
  for (let index = 1; index < frames.length; index++) {
    const previous = frames[index - 1]!;
    const current = frames[index]!;
    let impact = 0;
    let distance = 0;
    for (const [id, now] of current) {
      const was = previous.get(id);
      if (!was) {
        still.delete(id);
        continue;
      }
      const dx = now.box.x - was.box.x;
      const dy = now.box.y - was.box.y;
      const moved = Math.abs(dx) > MOVE_SLACK || Math.abs(dy) > MOVE_SLACK;
      const rested = (still.get(id) ?? 0) >= REST_FRAMES;
      if (now.animating || was.animating) {
        still.set(id, 0);
        continue;
      }
      if (!moved) {
        still.set(id, (still.get(id) ?? 0) + 1);
        continue;
      }
      if (!rested) {
        still.set(id, 0);
        continue;
      }
      if (now.targeted) continue;
      if (now.after && dy > 0 && Math.abs(dx) <= MOVE_SLACK) continue;
      if (now.before && dy < 0 && Math.abs(dx) <= MOVE_SLACK) continue;
      if (options.firstMoveFree && !freeUsed.has(id)) {
        freeUsed.add(id);
        continue;
      }
      const seen = union(clip(was.box, viewport), clip(now.box, viewport));
      if (seen.width <= 0 || seen.height <= 0) continue;
      impact += area(seen) / viewportArea;
      distance = Math.max(distance, Math.max(Math.abs(dx), Math.abs(dy)) / longer);
      if (moves.length < MAX_MOVES)
        moves.push({ label: now.label, frame: index, dx: Math.round(dx * 10) / 10, dy: Math.round(dy * 10) / 10 });
    }
    score += Math.min(1, impact) * distance;
  }
  return { score: Math.round(score * 1e5) / 1e5, moves };
}

/** How far the transcript's rows drifted over a run in which nothing new may move them. */
export type HeldDrift = {
  /** The largest distance, CSS px, of any row from where it was when first seen (0 when all held). */
  worst: number;
  /** The row that drifted furthest, and in which frame. */
  label?: string;
  frame?: number;
  /** Frames in which some row was off its first place by more than `MOVE_SLACK`. */
  driftFrames: number;
};

/**
 * The held-bottom detector (Leo, 2026-11-18, his chat sat at the bottom while clocks ticked and the
 * transcript bounced 30–70 px every second or so: "did we fix this scroll bounce at the bottom
 * yet?"). For a run in which nothing new arrives (a wait on a chat whose rows do not change: a
 * ticking status line, a running command's clock, the same snapshot sent again), every transcript row
 * must stay exactly where it was first seen, every frame. Unlike the box score and the follow judge,
 * nothing is exempt as a follow: a shared translation of every row that goes away and comes back over
 * a few hundred ms is a bounce, though the follow judge's reversal window (`REVERSE_FRAMES`) is too
 * short to see it. Rows a keyframe animation moves are skipped (an entrance); a row that leaves the
 * view and comes back is judged against where it first was.
 */
export function heldRowDrift(frames: readonly BoxFrame[]): HeldDrift {
  const first = new Map<number, number>();
  let worst = 0;
  let label: string | undefined;
  let frame: number | undefined;
  let driftFrames = 0;
  frames.forEach((current, index) => {
    let drifted = false;
    for (const [id, sample] of current) {
      if (!sample.row || sample.animating) continue;
      const y = sample.box.y;
      const at = first.get(id);
      if (at === undefined) {
        first.set(id, y);
        continue;
      }
      const off = Math.abs(y - at);
      if (off <= MOVE_SLACK) continue;
      drifted = true;
      if (off > worst) {
        worst = off;
        label = sample.label;
        frame = index;
      }
    }
    if (drifted) driftFrames++;
  });
  return { worst: Math.round(worst * 10) / 10, driftFrames, ...(label ? { label, frame } : {}) };
}

/** Samples the page's boxes after every painted frame until `stop`, which judges them as a held run
 *  (`heldRowDrift`): for a play step that waits on a chat nothing new reaches. */
export function startHeldTracker(doc: Document): { stop(): HeldDrift } {
  const frames: BoxFrame[] = [];
  const view = doc.defaultView!;
  const sample = () => {
    if (frames.length < MAX_FRAMES) frames.push(sampleBoxes(doc, null));
  };
  sample();
  const stopSampling = afterEachPaint(windowPaintClock(view), sample);
  return {
    stop() {
      stopSampling();
      sample();
      return heldRowDrift(frames);
    },
  };
}

/** A source of a browser layout-shift entry (`LayoutShift.sources`): the node and its rects. */
export type LayoutShiftSource = {
  node?: Node | null;
  previousRect?: Pick<DOMRectReadOnly, "x" | "y" | "width" | "height">;
  currentRect?: Pick<DOMRectReadOnly, "x" | "y" | "width" | "height">;
};

/**
 * Whether a browser layout-shift entry is the step's own expansion, under the box rules above: every
 * source it names is the target, holds it or is inside it (or inside the row opening at the very
 * bottom, `BOTTOM_FOLD`), follows it and moved straight down, or, while that row opens at the very
 * bottom, precedes it and moved straight up. The browser has no idea which row the reader clicked, so
 * without this its CLS scores the push every fold makes by design: the rows under an opening tool
 * call sliding down with it. It scored only the slice of that push inside the step's settle window
 * (a few frames), so a fold whose curve moves more of its height in its first frames read as a
 * bigger shift, though every row went to the same place. With several targets (a step's own and
 * what the play clicked right before it), a source is exempt by any one of them.
 */
export function isExpansionShift(sources: readonly LayoutShiftSource[], target: StepTargets): boolean {
  const targets = targetList(target);
  if (!targets.length || !sources.length) return false;
  return sources.every((source) => targets.some((each) => expandedBy(source, each)));
}

function expandedBy({ node, previousRect: was, currentRect: now }: LayoutShiftSource, target: Element): boolean {
  const folding = bottomFoldOf(target);
  const element = node && node.nodeType === 1 ? (node as Element) : (node?.parentElement ?? null);
  if (!element || !was || !now) return false;
  if (element === target || element.contains(target) || target.contains(element) || folding?.contains(element))
    return true;
  const position = target.compareDocumentPosition(element);
  const following = (position & 4) !== 0; // DOCUMENT_POSITION_FOLLOWING
  // A box with no previous area (a clipped shimmer band in the line under the fold) only came
  // into view: no move of its own to judge, so it goes with the rows it sits in.
  if (was.width <= 0 || was.height <= 0) return following;
  // One with no current area left the view: the browser clips its new rect to nothing, so the rect
  // says nothing of where it went. A row after the target that an opening pushed past the
  // transcript's bottom (the running turn's live line under a digest that opens whole) is the
  // expansion's push; judge it by where its box is now, which must be straight below where it was.
  if (now.width <= 0 || now.height <= 0) {
    if (!following) return false;
    const live = element.getBoundingClientRect();
    return Math.abs(live.x - was.x) <= MOVE_SLACK && live.y > was.y + MOVE_SLACK;
  }
  const dx = now.x - was.x;
  const dy = now.y - was.y;
  if (Math.abs(dx) > MOVE_SLACK) return false;
  if (following) return dy > 0; // pushed down
  return !!folding && (position & 2) !== 0 && dy < 0; // DOCUMENT_POSITION_PRECEDING, at the bottom
}

// ---- Sampling the live page ----

/** Most frames one tracker keeps (about 33 s at 60 Hz); a longer run scores its first frames. */
const MAX_FRAMES = 2000;

/** What `afterEachPaint` schedules with: a window, or a stand-in in a unit test. */
export interface PaintClock {
  requestAnimationFrame(callback: (time: number) => void): number;
  cancelAnimationFrame(handle: number): void;
  /** Posts `then` as a task: a message posted from a frame callback runs after that frame renders. */
  afterThisFrame(then: () => void): void;
  /** Adds a capturing listener for the input events that come before a pending read. */
  onInput?(listener: () => void): () => void;
  /** Watches the page between a frame's render and the read after it: `changed` when its DOM
   *  changes, `rendered` once per `arm` (called in a frame callback), after the page's own observers
   *  placed what that frame paints. */
  watchChanges?(changed: () => void, rendered: () => void): { arm(): void; stop(): void };
}

/** Reads dropped in a row because the page changed before them; the next one reads regardless, so a
 *  page that changes after every paint is still sampled (every so many frames). */
export const MAX_CHANGED_DROPS = 8;

/** Input that can change the page between a frame and the read after it (paintedFrames.ts). */
const INPUT_EVENTS = [
  "keydown",
  "beforeinput",
  "input",
  "pointerdown",
  "pointerup",
  "mousedown",
  "mouseup",
  "click",
  "wheel",
];

export function windowPaintClock(view: Window): PaintClock {
  return {
    requestAnimationFrame: (callback) => view.requestAnimationFrame(callback),
    cancelAnimationFrame: (handle) => view.cancelAnimationFrame(handle),
    afterThisFrame(then) {
      const channel = new (view as Window & typeof globalThis).MessageChannel();
      channel.port1.onmessage = () => {
        channel.port1.close();
        then();
      };
      channel.port2.postMessage(null);
    },
    onInput(listener) {
      for (const kind of INPUT_EVENTS) view.addEventListener(kind, listener, { capture: true, passive: true });
      return () => {
        for (const kind of INPUT_EVENTS) view.removeEventListener(kind, listener, { capture: true });
      };
    },
    watchChanges(changed, rendered) {
      const doc = view.document;
      const page = view as Window & typeof globalThis;
      if (typeof page.MutationObserver !== "function" || typeof page.ResizeObserver !== "function")
        return { arm() {}, stop() {} };
      const mutations = new page.MutationObserver(changed);
      mutations.observe(doc, { subtree: true, childList: true, attributes: true, characterData: true });
      // Observed afresh in each frame callback, the root reports in that frame's observer step, after
      // the observers the page made before this one (the transcript placing its rows): what they
      // changed is what the frame paints. A change delivered after it came after the render.
      const probe = doc.documentElement;
      const renders = new page.ResizeObserver(() => {
        mutations.takeRecords();
        rendered();
      });
      return {
        arm() {
          renders.unobserve(probe);
          renders.observe(probe);
        },
        stop() {
          mutations.disconnect();
          renders.disconnect();
        },
      };
    },
  };
}

/**
 * Calls `read` once after each painted frame until the returned stop. A frame callback runs before
 * the frame's style, layout, ResizeObserver callbacks and paint, so a read there can see a layout
 * no frame paints (the transcript's lift before its dock observer ran, #46151): the read waits for
 * a task posted from the frame callback instead. An input event before that task runs the read
 * first, on the state the frame painted. Any other task can run before it too (a busy page's queued
 * message: a streamed reply's render), and the layout it leaves is painted only after the next frame's
 * observers place the rows under it, so a read after it saw a reply a line taller over a live line
 * that never painted there, and then that line jumping (agent-chat-stream-no-shift `text`, 22.8 px
 * on a loaded runner). Such a read is dropped, as one the next frame overtook is (`watchChanges`; at
 * most MAX_CHANGED_DROPS in a row).
 */
export function afterEachPaint(clock: PaintClock, read: () => void): () => void {
  let stopped = false;
  let handle = 0;
  // The frame whose read has not run yet; a read runs at most once, and only while it is pending.
  let pending = 0;
  let frames = 0;
  // The page changed after the last frame rendered (`watchChanges`), and reads dropped for it in a row.
  let changed = false;
  let drops = 0;
  const watch = clock.watchChanges?.(
    () => {
      changed = true;
    },
    () => {
      changed = false;
    },
  );
  const runFor = (frameNumber: number) => {
    if (stopped || frameNumber === 0 || pending !== frameNumber) return;
    pending = 0;
    if (changed && drops < MAX_CHANGED_DROPS) {
      drops += 1;
      return;
    }
    drops = 0;
    read();
  };
  const offInput = clock.onInput?.(() => runFor(pending)) ?? (() => {});
  const frame = () => {
    if (stopped) return;
    watch?.arm();
    // A read whose task did not come before the next frame would see this frame's unpainted layout:
    // it is dropped (the next read sees both frames' moves).
    const frameNumber = ++frames;
    pending = frameNumber;
    clock.afterThisFrame(() => runFor(frameNumber));
    handle = clock.requestAnimationFrame(frame);
  };
  handle = clock.requestAnimationFrame(frame);
  return () => {
    stopped = true;
    pending = 0;
    clock.cancelAnimationFrame(handle);
    offInput();
    watch?.stop();
  };
}

/**
 * Samples after every painted frame until `stop`, which scores what it saw. It judges the same frames for
 * the follow (followJudge.ts) and against the layout-motion contract (`motion`: every move no declaration
 * covers, layout/motionJudge.ts): the moves the step declares (`declared`, the play's own act) and those the
 * page declares while it runs (`declareMove`). Chat media is sampled for that judgement only, so the
 * box-shift score keeps its rows.
 */
export function startBoxTracker(
  doc: Document,
  options: {
    target?: StepTargets;
    extra?: () => Element[];
    firstMoveFree?: boolean;
    restedAtStart?: boolean;
    declared?: () => JudgeFrame["declared"];
  } = {},
): { stop(): BoxShift } {
  const frames: BoxFrame[] = [];
  const judged: JudgeFrame[] = [];
  const view = doc.defaultView!;
  const targetsNow = () => [
    ...targetList(options.target ?? null),
    // A move the page declares on targets (an expand it runs itself) relates boxes to those targets too.
    ...openDeclarations().flatMap((declaration) => declaration.targets ?? []),
  ];
  const score = () => {
    frames.push(sampleBoxes(doc, targetsNow(), options.extra?.() ?? []));
  };
  const judge = () => {
    const open = openDeclarations();
    const media = [...doc.querySelectorAll(MEDIA_SELECTOR)];
    const samples = sampleBoxes(doc, targetsNow(), [...(options.extra?.() ?? []), ...media]);
    const declared = [
      ...(options.declared?.() ?? []),
      ...open.map(({ key, event, scope, once, by }) => ({ key: -key, event, scope, once, by })),
    ];
    judged.push({ samples, declared });
    // A play that sets `cmuxMotionTrace` on its window logs each judged frame (undeclared-run.sh TRACE=1).
    if ((view as unknown as { cmuxMotionTrace?: boolean }).cmuxMotionTrace) {
      const rows = [...samples].filter(([, sample]) => sample.surface === "transcript-row").slice(-6);
      console.log(
        `motion-trace judge f${judged.length - 1} t${view.performance.now().toFixed(0)} ${rows.map(([id, { box }]) => `${id}:${box.y.toFixed(1)}/${box.height.toFixed(1)}`).join(" ")}`,
      );
    }
  };
  // The viewport the last frame drew at. A resize that lands between that frame and its read (the
  // message waits behind other tasks) shows the new width's rewrapped rows before the page's
  // ResizeObserver placed them, a state no frame paints: the judge skips that read and takes the next frame's.
  let drewAt = "";
  const viewportNow = () => `${view.innerWidth}x${view.innerHeight}`;
  const clock = windowPaintClock(view);
  const stopSampling = afterEachPaint(
    {
      ...clock,
      requestAnimationFrame: (callback) =>
        clock.requestAnimationFrame((time) => {
          drewAt = viewportNow();
          callback(time);
        }),
    },
    () => {
      if (frames.length < MAX_FRAMES) score();
      if (judged.length < MAX_FRAMES && viewportNow() === drewAt) judge();
    },
  );
  // The page as it is when the step starts, at rest.
  score();
  judge();
  return {
    stop() {
      stopSampling();
      score();
      judge();
      const shift = scoreBoxFrames(frames, { width: view.innerWidth, height: view.innerHeight }, options);
      // A step starts on a page that has been still: its first frame's boxes have rested already.
      if (options.restedAtStart && judged.length) judged.unshift(...Array.from({ length: 2 }, () => judged[0]!));
      return { ...shift, follow: judgeFollowFrames(frames, options), motion: judgeMotion(judged) };
    },
  };
}
