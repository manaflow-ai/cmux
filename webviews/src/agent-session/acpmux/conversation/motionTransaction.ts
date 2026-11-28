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
//   tx.ride(animation)              a box that changes size with the rows' move (the composer field a
//                                   send clears) plays on the plan's clock: still while held, then its
//                                   share of the way done follows the rows' share, landing as they land
import { MOTION_MS } from "../../../motion/scale.generated";
import { experimentArm } from "../../../experiments/experiment";
import { compoundMotion } from "./compoundMotion.experiment";
import { cssTimeMs, foldMotion, foldMs } from "./fold";
import { setEffectKeyframes } from "./keyframeKinds";

/// Under this share of the plan left, a move starts a new plan instead of scaling the rest (the scale
/// 1 / r would grow without bound as the plan ends).
export const JOIN_FLOOR = 0.25;
/// A shift smaller than this moves nothing (sub-pixel layout noise).
const MOVE_FLOOR = 0.5;
/// How long `expect` holds the rows by default when nothing releases it: the standard motion step.
export const EXPECT_BOUND_MS = MOTION_MS.standard;
/// A rider's animation is retimed to this many ms on a linear curve, so its current time is its share done.
const RIDE_SPAN = 1000;

export type MotionPlan = {
  /// The offset at `start`, px (the rows are drawn `amount` px from their layout and go home).
  amount: number;
  /// When the plan starts on the document timeline, ms.
  start: number;
  /// How long it plays, ms.
  duration: number;
  /// Its curve (CSS easing); the fold's when unset.
  easing?: string;
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
  /// `animation` (a box's own size change, two or more keyframes) plays on the plan's clock from now on.
  ride: (animation: Animation) => void;
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

/// A keyframe's style alone: its own offset, easing and composite go.
const keyframeStyle = ({
  offset: _o,
  computedOffset: _c,
  easing: _e,
  composite: _m,
  ...style
}: ComputedKeyframe): Keyframe => style;

const transactions = new WeakMap<HTMLElement, ThreadTransaction>();

/// SEND-RISE (composerStates.css). Leo, 2026-11-22, after the send pop: "the chat transcript above
/// doesn't quite smoothly account for things." With the pop on, a send's held shift (a tall prompt's
/// composer collapse and its rows) plays on the pop's clock and curve, so the rows above and the
/// collapsing field rest with the bubble; on the fold's 180 ms clock they rested at 283 ms while the
/// bubble popped on for 450 ms. With the pop off: undefined, the fold's clock as before.
function sendRise(thread: HTMLElement): { ms: number; easing: string | undefined } | undefined {
  if (!thread.closest('[data-send-pop]:not([data-send-pop="none"])')) return undefined;
  const style = getComputedStyle(thread);
  const ms = cssTimeMs(style.getPropertyValue("--agent-motion-send-rise"));
  if (!(ms !== undefined && ms > 0)) return undefined;
  return { ms, easing: style.getPropertyValue("--agent-ease-send-rise").trim() || undefined };
}

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
  /// The open hold is a send's: its shift plays on the rise's clock when the pop is on (`sendRise`).
  let sending = false;
  /// Where the thread was drawn as the hold began (its box's top), px.
  let holdTop = 0;
  let moved: string[] = [];
  /// The animations riding the plan: `share` done drawn now, `from` the share and `base` the offset (px)
  /// when the plan drawing now started; the share goes from `from` to 1 as the offset goes from `base` to 0.
  let riders: { animation: Animation; share: number; from: number; base: number }[] = [];
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
  /// The riders land where they end (their own `finish` lets their owner rest).
  const landRiders = () => {
    const landing = riders;
    riders = [];
    for (const rider of landing) if (rider.animation.playState !== "idle") rider.animation.finish();
  };
  /// The hold ended with nothing for the rows to move (a queued send whose row never came): each rider
  /// plays the rest of its way on its own over `ms`, on the plan's curve, instead of landing in a frame.
  const glideRiders = (ms: number, easing?: string) => {
    const gliding = riders;
    riders = [];
    for (const { animation, share } of gliding) {
      if (animation.playState === "idle") continue;
      const effect = animation.effect;
      if (!(effect instanceof KeyframeEffect) || !effect.target || !(ms > 0) || share >= 1) {
        animation.finish();
        continue;
      }
      // From where it is drawn now to its last keyframe (the properties it animates, read as drawn).
      const last = keyframeStyle(effect.getKeyframes().at(-1)!);
      const drawnStyle = getComputedStyle(effect.target);
      const from: Keyframe = {};
      for (const key of Object.keys(last))
        from[key] = drawnStyle.getPropertyValue(key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`));
      setEffectKeyframes(effect, [from, last]);
      effect.updateTiming({ duration: ms, easing: easing ?? foldMotion.easing(thread) });
      animation.currentTime = 0;
      animation.play();
    }
  };
  /// Each rider at the plan's share done: the rows' offset gone from `base` toward 0. While held, still.
  const drawRiders = () => {
    // One its owner cancelled (a new edit retargeted the field) rides no more.
    riders = riders.filter((rider) => rider.animation.playState !== "idle");
    if (holds.size > 0) return;
    const at = planOffset(plan, progress());
    for (const rider of riders) {
      const left = Math.abs(rider.base) >= MOVE_FLOOR ? Math.min(1, Math.max(0, at / rider.base)) : 0;
      rider.share = rider.from + (1 - rider.from) * (1 - left);
      rider.animation.currentTime = rider.share * RIDE_SPAN;
    }
  };
  /// A plan starts drawing (played, joined or restarted): each rider goes on from the share it drew.
  const rebaseRiders = () => {
    const at = planOffset(plan, progress());
    for (const rider of riders) {
      rider.from = rider.share;
      rider.base = at;
    }
  };
  const finish = () => {
    clear();
    plan = undefined;
    moved = [];
    landRiders();
  };
  /// Sets the plan's animation to the time since its start; past its end the plan is done.
  const drawTime = () => {
    if (!plan || !drawn || holds.size > 0) return;
    const elapsed = Math.max(0, now() - plan.start);
    if (elapsed >= plan.duration) finish();
    else {
      drawn.currentTime = elapsed;
      drawRiders();
    }
  };
  const drawPlan = () => {
    clear();
    if (!plan) return;
    drawn = paused(
      [{ translate: `0 ${plan.amount}px` }, { translate: "0 0" }],
      plan.duration,
      plan.easing ?? foldMotion.easing(thread),
    );
    // At its time before the riders read the offset it starts them from (a joined plan began earlier).
    drawn.currentTime = Math.min(plan.duration, Math.max(0, now() - plan.start));
    rebaseRiders();
    drawTime();
    loop();
  };
  const play = () => {
    const ms = foldMs(thread);
    const rise = sending && ms > 0 ? sendRise(thread) : undefined;
    if (holds.size > 0) {
      drawHeld();
      return;
    }
    if (Math.abs(held) >= MOVE_FLOOR) {
      // The hold's whole shift, joined with what still plays (rows already drawn off by it).
      const rest = planOffset(plan, progress());
      plan =
        ms > 0
          ? { amount: held + rest, start: now(), duration: rise?.ms ?? ms, ...(rise && { easing: rise.easing }) }
          : undefined;
    }
    held = 0;
    sending = false;
    if (!plan || !(plan.duration > 0)) {
      glideRiders(rise?.ms ?? ms, rise?.easing);
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
      if (source === "send") sending = true;
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
    ride(animation) {
      const effect = animation.effect;
      const frames = effect instanceof KeyframeEffect ? effect.getKeyframes() : [];
      if (!(effect instanceof KeyframeEffect) || frames.length < 2 || !(foldMs(thread) > 0)) return;
      // Its own curve and length go: from its first keyframe to its last, its time its share done.
      setEffectKeyframes(effect, [keyframeStyle(frames[0]!), keyframeStyle(frames.at(-1)!)]);
      effect.updateTiming({ duration: RIDE_SPAN, easing: "linear", delay: 0, endDelay: 0, iterations: 1 });
      animation.pause();
      animation.currentTime = 0;
      const rider = { animation, share: 0, from: 0, base: planOffset(plan, progress()) };
      riders.push(rider);
      if (holds.size === 0 && !plan) {
        // Nothing to ride: it lands with the rows, which are already home.
        landRiders();
        return;
      }
      drawRiders();
    },
    freeze() {
      const at = tx.offset();
      tx.cancel();
      return at;
    },
    cancel() {
      holds.clear();
      held = 0;
      sending = false;
      plan = undefined;
      moved = [];
      clear();
      landRiders();
    },
    sources: () => moved,
  };
  return tx;
}
