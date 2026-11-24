// One motion for the thread when several things move it at once (Leo, 2026-11-22: "when i send it
// collapses the compser then sends it to you... but i think we should be able to calculate it out to
// be like one smooth motion. there are a lot of these possible compound movement situations, esp with
// folds, that i think we can watch for and map out harder to have more cohesive animations").
//
// A UI change is a state transition: its start state is where the rows are drawn, its end state is
// where layout puts them. Every mover that shifts the rows in a frame (the bottom stack's room, the
// composer field's growth, a send's rows landing, a scroll the follow makes at once) reports its
// shift here instead of playing its own glide. The transaction keeps ONE plan per thread:
//
//   offset(t) = amount * (1 - curve((t - start) / duration))
//
// drawn as one Web Animation (`translate`, composite add) on the thread. Moves in the same frame read
// the same `document.timeline` time, so they add into one plan. A move while the plan plays joins it:
// the remaining share r = 1 - curve(p) keeps the start, the curve and the end, and the amount grows by
// delta / r, so the drawn rows never jump; past JOIN_FLOOR it starts a new plan from where the rows
// are drawn. `expect(source)` holds the drawn rows still while a paired change is still to come (a
// send's prompt row, after its composer cleared), then the whole net shift plays as one motion.
//
// The API other movers plug into (lane/composer-send-one-motion's send, the turn's end fold in #49624):
//   const tx = threadTransaction(thread);
//   tx.move(delta, "source")        layout just shifted the rows by delta px: start drawn where they were
//   tx.expect("send", boundMs)      hold the rows still until release("send") or boundMs
//   tx.settle("pass")               while held: rows a pass moved at once stay drawn where they were
//   tx.release("send")              the paired change landed: the held shift plays as one motion
//   tx.freeze()                     the reader took the view: stop where drawn, return the drawn offset
//   tx.offset()                     the offset drawn now, px
import { MOTION_MS } from "../../../motion/scale.generated";
import { experimentArm } from "../../../experiments/experiment";
import { compoundMotion } from "./compoundMotion.experiment";
import { foldMotion, foldMs } from "./fold";

/// Under this share of the plan left, a move starts a new plan instead of scaling the rest (the scale
/// 1 / r would grow without bound as the plan ends).
export const JOIN_FLOOR = 0.25;
/// A shift smaller than this moves nothing (sub-pixel layout noise).
const MOVE_FLOOR = 0.5;
/// How long `expect` holds the rows by default when nothing releases it: the standard motion step.
export const EXPECT_BOUND_MS = MOTION_MS.standard;

export type MotionPlan = {
  /// The offset at `start`, px (the rows are drawn `amount` px from their layout and go home).
  amount: number;
  /// When the plan starts on the document timeline, ms.
  start: number;
  /// How long it plays, ms.
  duration: number;
};

/// What the plan becomes when `delta` px of layout shift lands at `now`, while `plan` plays with
/// `progress` (the curve's eased share done, 0..1). Pure: the planner's whole rule.
export function joinPlan(
  plan: MotionPlan | undefined,
  progress: number,
  delta: number,
  now: number,
  duration: number,
): MotionPlan {
  if (!plan || progress >= 1) return { amount: delta, start: now, duration };
  const left = 1 - progress;
  if (left >= JOIN_FLOOR) return { ...plan, amount: plan.amount + delta / left };
  return { amount: plan.amount * left + delta, start: now, duration };
}

/// The offset `plan` draws with `progress` of its curve done.
export const planOffset = (plan: MotionPlan | undefined, progress: number): number =>
  plan ? plan.amount * (1 - Math.min(1, Math.max(0, progress))) : 0;

export type ThreadTransaction = {
  move: (delta: number, source: string) => void;
  expect: (source: string, boundMs?: number) => void;
  release: (source: string) => void;
  /// While a hold is open: the pass placed the rows (a scroll the follow made at once, rows that
  /// came); they stay drawn where the hold began, the shift joining the held one. One box read.
  settle: (source: string) => void;
  expecting: () => boolean;
  /// Whether a plan plays or a hold is open.
  active: () => boolean;
  offset: () => number;
  freeze: () => number;
  cancel: () => void;
  /// The sources that moved the current plan, for traces and the harness.
  sources: () => readonly string[];
};

/// The attribute a host sets to pick the arm for the chats under it (the gallery's before and after
/// side by side); else the page's arm of compound-motion.
export const COMPOUND_MOTION_ATTR = "data-compound-motion";
/// Whether the thread runs the transaction. One `closest` walk per move.
export const transactionOn = (thread: Element): boolean =>
  (thread.closest(`[${COMPOUND_MOTION_ATTR}]`)?.getAttribute(COMPOUND_MOTION_ATTR) ?? experimentArm(compoundMotion)) ===
  "transaction";

const transactions = new WeakMap<HTMLElement, ThreadTransaction>();

/// The thread's one transaction (made on first use, weakly held with the element).
export function threadTransaction(thread: HTMLElement): ThreadTransaction {
  let tx = transactions.get(thread);
  if (!tx) transactions.set(thread, (tx = makeTransaction(thread)));
  return tx;
}

function makeTransaction(thread: HTMLElement): ThreadTransaction {
  let plan: MotionPlan | undefined;
  let drawn: Animation | undefined;
  /// The open holds: source -> when it lapses (timers' clock, ms).
  const holds = new Map<string, number>();
  /// The shift held while a hold is open, px: drawn still at `held` from layout.
  let held = 0;
  /// Where the thread was drawn as the hold began (its box's top), px.
  let holdTop = 0;
  let moved: string[] = [];
  /// The frame loop that draws the plan and lapses holds, while either is open.
  let frame: number | undefined;
  const now = () => {
    const time = thread.ownerDocument.timeline?.currentTime;
    return typeof time === "number" ? time : performance.now();
  };
  // A hold's bound is on the timers' clock (performance.now): the clock the page's frames and its
  // own timers read on any host (frameClock.ts moves it with drawn frames).
  const clock = () => performance.now();
  const progress = () => {
    const value = drawn?.effect?.getComputedTiming().progress;
    if (!plan) return 1;
    if (typeof value === "number") return value;
    // Not playing yet or done: before the start draws the whole amount, after the end none.
    return now() < plan.start ? 0 : 1;
  };
  const clear = () => {
    drawn?.cancel();
    drawn = undefined;
  };
  /// A paused animation the frame loop sets: it draws on the page's own frames, never on whether the
  /// renderer's timeline ticks (a host that never advanced it left the rows drawn where the send began,
  /// the sent prompt below the fold: GitHub's runner, run 45015659896).
  const paused = (keyframes: Keyframe[], duration: number, easing?: string) => {
    const animation = thread.animate(keyframes, { duration, easing, fill: "forwards", composite: "add" });
    animation.pause();
    return animation;
  };
  const drawHeld = () => {
    clear();
    if (Math.abs(held) < MOVE_FLOOR / 2) return;
    // Still at `held` for as long as the hold lasts; the release replaces it.
    drawn = paused([{ translate: `0 ${held}px` }, { translate: `0 ${held}px` }], 1);
  };
  const finish = () => {
    clear();
    plan = undefined;
    moved = [];
  };
  /// Sets the plan's animation to the time since its start; past its end the plan is done.
  const drawTime = () => {
    if (!plan || !drawn || holds.size > 0) return;
    const elapsed = Math.max(0, now() - plan.start);
    if (elapsed >= plan.duration) finish();
    else drawn.currentTime = elapsed;
  };
  const drawPlan = () => {
    clear();
    if (!plan) return;
    drawn = paused(
      [{ translate: `0 ${plan.amount}px` }, { translate: "0 0" }],
      plan.duration,
      foldMotion.easing(thread),
    );
    drawTime();
    loop();
  };
  const play = () => {
    const ms = foldMs(thread);
    if (holds.size > 0) {
      drawHeld();
      return;
    }
    if (Math.abs(held) >= MOVE_FLOOR) {
      // The hold's whole shift, joined with what still plays (rows already drawn off by it).
      const rest = planOffset(plan, progress());
      plan = ms > 0 ? { amount: held + rest, start: now(), duration: ms } : undefined;
    }
    held = 0;
    if (!plan || !(plan.duration > 0)) {
      finish();
      return;
    }
    drawPlan();
  };
  const lapse = () => {
    if (holds.size === 0) return;
    const at = clock();
    for (const [source, until] of holds) if (until <= at) holds.delete(source);
    if (holds.size === 0) play();
  };
  /// One callback a frame while a hold is open or a plan draws; it stops with both.
  const step = () => {
    frame = undefined;
    lapse();
    drawTime();
    if (holds.size > 0 || plan) loop();
  };
  const loop = () => {
    if (frame === undefined) frame = thread.ownerDocument.defaultView?.requestAnimationFrame(step);
  };
  const tx: ThreadTransaction = {
    move(delta, source) {
      if (!(Math.abs(delta) >= MOVE_FLOOR)) return;
      const ms = foldMs(thread);
      if (!(ms > 0)) {
        // Motion off, reduced, or a jump look: everything lands at once.
        tx.cancel();
        return;
      }
      moved.push(source);
      if (holds.size > 0) {
        held += delta;
        drawHeld();
        return;
      }
      plan = joinPlan(plan, progress(), delta, now(), ms);
      drawPlan();
    },
    expect(source, boundMs = EXPECT_BOUND_MS) {
      if (!(foldMs(thread) > 0)) return;
      const start = holds.size === 0;
      holds.set(source, clock() + boundMs);
      if (start) {
        // The rows stop where they are drawn: what still plays becomes part of the held shift.
        held += planOffset(plan, progress());
        plan = undefined;
        drawHeld();
        holdTop = thread.getBoundingClientRect().top;
      }
      loop();
    },
    release(source) {
      if (!holds.delete(source)) return;
      if (holds.size === 0) play();
    },
    settle(source) {
      if (holds.size === 0) return;
      const delta = holdTop - thread.getBoundingClientRect().top;
      if (!(Math.abs(delta) >= MOVE_FLOOR)) return;
      moved.push(source);
      held += delta;
      drawHeld();
    },
    expecting: () => holds.size > 0,
    active: () => holds.size > 0 || drawn !== undefined,
    offset: () => (holds.size > 0 ? held : planOffset(plan, progress())),
    freeze() {
      const at = tx.offset();
      tx.cancel();
      return at;
    },
    cancel() {
      holds.clear();
      held = 0;
      plan = undefined;
      moved = [];
      clear();
    },
    sources: () => moved,
  };
  return tx;
}
