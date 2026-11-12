// The followed transcript's motion on a send and while a reply streams (Leo, 2026-11-07: "When it
// comes to sending messages, I feel like the jump, the jolt is a bit too jarring ... the way the
// messages actually stream through, like, that can be made a lot smoother ... what is satisfying at
// 120 hertz? That's what we want to aim at.").
//
// The view's offset still lands at the latest row in the pass that moved it, before the frame
// paints (VirtualTranscript's follow, "IMMEDIATELY ... at the bottom", Leo 2026-10-21); only what the
// reader sees moves smoothly. Each pass measures how far the rows the reader sees moved on screen
// (VirtualTranscript `chaseFollow`: a row in view, before and after), whatever moved them: a new
// line, the sent prompt's row and the live line arriving, the composer's card shrinking as it
// clears, a block landing. The thread is drawn back by exactly that (`translate`, so layout, the
// scroll offset and the scrollbar stay exact) and the drawn offset chases home on the display's
// frames. Every move in a pass is one displacement of one chase, so the bubble, the rows above it
// and the composer's room move together, and a move that comes while one plays continues from where
// the thread is drawn and how fast it is going: no restart, no jolt per chunk.
//
// The chase (the `spring` arm and the default `blocks` arm of followMotion.experiment.ts) is a
// critically damped spring over the motion scale's standard step (no overshoot, so nothing moves
// away from where it rests), at most CHASE_MAX_SPEED px/s (under 4 px a 120 Hz frame) while it
// trails by under a line, and faster past that. The trail is bounded to CHASE_MAX_TRAIL_LINES (two
// lines): a block that lands past it catches up within BURST_S (six 120 Hz frames), never in one
// jump, and no frame moves more than CHASE_MAX_FRAME_LINES (a line). In the default `blocks` arm
// content may pass under the glass composer while it settles, held only by that bound (cmux#37614);
// the `spring` arm keeps new text at most a line under the bottom stack (VirtualTranscript
// CHASE_UNDER_STACK_PX) and moves the rest at once, as followGlide.ts did. A
// send's rows rise out from behind the composer they left in every arm (`below` unbounded).
//
// Stop condition: the frame loop runs only while the thread is drawn away from its layout and ends
// at rest (within REST_PX and REST_SPEED); `stop` ends it at once (Jump to latest, a chat switch, a
// resize, a fold that animates the thread itself, unmount), and `hold` ends the loop where the
// thread is drawn (reader input: the reader's view moves only with their scroll). With Reduce Motion, the
// host's motion switch off (`data-agent-motion`/`data-cmux-motion`) or a zero move token, `shift`
// moves nothing and the view steps at once, as before.
import { MOTION_MS } from "../../../motion/scale.generated";
import { motionMode } from "../../../ui/motion/motionMode";
import { currentChatMetrics } from "../chatDisplay";
import { bezierAt, parseBezier } from "../../../ui/cubicBezier";
import { MAX_FRAME_STEP_MS } from "../threadMinimap/scrollMotion";
import { cssTimeMs } from "./fold";
import { FOLLOW_GLIDE_OFF } from "./followGlide";
import type { FollowMotionArm } from "./followMotion.experiment";
import { drawPinned } from "./pinnedLiveLine";

/// The spring's response: the motion scale's standard step (180 ms, the glide it replaces), damping 1
/// (critically damped), as the native `move` spring (motion.md, 150 ms) is.
const RESPONSE_S = MOTION_MS.standard / 1000;
/// The most the chase moves the rows in a second while it is near home: 3.75 px a 120 Hz frame (7.5
/// at 60 Hz), a sixth of a line, within CATCH_UP_LINES of home.
export const CHASE_MAX_SPEED = 450;
/// The most the view trails the newest line, in the chat's lines (chatDisplay's line height, so it
/// follows the reader's font settings). What lands past it (a block faster than the chase) is
/// brought back within BURST_S, never in one jump: the chase moves at least the excess over
/// BURST_S a second until it is back inside the bound, and on at that speed to a line
/// (CATCH_UP_LINES), so the next block has room under the bound.
export const CHASE_MAX_TRAIL_LINES = 2;
/// How soon (s) the trail is back within its bound after a block lands past it: six 120 Hz frames.
export const BURST_S = 0.05;
/// The most any frame moves the rows, in the chat's lines per 120 Hz frame.
export const CHASE_MAX_FRAME_LINES = 1;
/// How much of a reply's growth (not a send's rise) the `blocks` arm draws back, in lines. Past it,
/// the frame the text lands in moves the rest at once, up to CHASE_LAND_LINES with the chase's
/// step in that frame; the chase takes what is left. Holding a whole block back pushed the live
/// line under the reply down by the block and then raised it again: the streaming-text gallery's
/// live line travelled 2110 px down where base's travelled 1393 px (shift 3.07, baseline 2.25).
export const CHASE_HOLD_LINES = 1;
/// A row that arrived above the live line (a finished call taking its row, a thought's row and the
/// reply's first words, a steer) holds all of its move back: nothing of it moves at once in the frame
/// it lands. Moving CHASE_LAND_LINES of it at once moved the rows the reader sees 18-21 px in that
/// one frame (turn-transition-jumps.test.ts). The chase then brings it home on the arrival step
/// (`arrivalStep`): one timed curve that ends on its last frame, not the spring, whose tail crept the
/// last pixels home and snapped them 228 ms after a call finished (Leo, 2026-11-09: "there's some
/// sort of "settling" and like ok maybe but the animations end to end need to just resolve faster";
/// row-arrival-settle.test.ts). The rows under it glide on the same step (tailGlide.ts), and the row
/// that came fades in on it (`--agent-motion-arrive`), so everything that moves starts in the frame
/// the row lands in and rests together.
export const CHASE_ARRIVAL_HOLD_LINES = Number.POSITIVE_INFINITY;
/// In the earlier looks (the spring brings an arrival home), how soon (s) the trail is back within its
/// bound after a row that arrived put it past: 18 120 Hz frames, so a steer and the call it came under
/// (115 px) come in at under a third of a line a frame. A reply's own growth keeps BURST_S.
export const ARRIVAL_BURST_S = 0.075;
/// The most an arrival's step moves the rows in one 120 Hz frame, in lines: under the two thirds of a
/// line turn-transition-jumps.test.ts holds every transition's frames to.
export const ARRIVAL_FRAME_LINES = 0.6;
/// The arrival step's curve: a sine ease-out, whose first frame moves π/2 times the step's mean (a
/// quadratic ease-out moves twice it, so a long move would need a longer step for the same frame).
export const ARRIVAL_EASE = "cubic-bezier(0.39, 0.575, 0.565, 1)";
const arrivalEase = (progress: number) => Math.sin((progress * Math.PI) / 2);
/// The arrival step for a move of `px` (ms): the motion scale's quick step (80 ms), longer only as a
/// move past about 70 px needs to keep each frame under ARRIVAL_FRAME_LINES (115 px: 110 ms), at the
/// host's speed `scale` (the speed factor of `--agent-motion-move`; 0 with motion off). `floor`: the
/// shortest step (a move during a step keeps that step's end, so its floor is the time left).
export function arrivalStepMs(px: number, scale = 1, floor = MOTION_MS.quick * scale): number {
  const frames = ((Math.PI / 2) * Math.abs(px)) / (ARRIVAL_FRAME_LINES * currentChatMetrics().lineHeight);
  return Math.max(floor, (frames * 1000) / 120);
}
/// The most a landing frame moves, that at once and the chase's step in it together, in lines:
/// under the 0.85 of a line that 95 in 100 of the stream's frames keep to (send-stream-motion.test.ts).
export const CHASE_LAND_LINES = 0.8;
/// How far behind its layout the thread may be drawn at all, in viewports; only a move past that
/// (a whole screen landing at once) moves at once.
const CHASE_MAX_LAG = 0.75;
/// Past this many lines behind the chase speeds up by what is further behind over CATCH_UP_S
/// (at the bound, 600 px/s: 5 px a 120 Hz frame).
const CATCH_UP_LINES = 1;
const CATCH_UP_S = 0.15;
/// At rest: drawn within this of its layout and moving slower than REST_SPEED px/s.
const REST_PX = 0.25;
const REST_SPEED = 4;
/// A frame gap longer than this (a hidden page, a long task) integrates as this long: the shared
/// scroll clock's paced rides use the same bound (scrollMotion.ts).
const MAX_STEP_S = MAX_FRAME_STEP_MS / 1000;
/// A frame asked for this long ago (ms) and still not run: the page draws no frames (its workspace
/// switched away covers or parks its view while it still reads visible). What lands meanwhile moves
/// at once, so the first frame back draws the rows where they rest instead of a chase held back the
/// whole time away (Leo, 2026-11-11: "austin was navigating between workspaces ... a sliver of
/// space at the bottom"; agent-pane-reveal-in-place.shared.ts). A busy page still runs a frame well
/// within it.
const FRAMELESS_MS = 150;
/// The fixed-duration arm's step: the standard step, eased out (MOTION_EASE_OUT's start slope).
const CHUNK_S = MOTION_MS.standard / 1000;

export type FollowChase = {
  readonly arm: FollowMotionArm;
  /// The rows the reader sees moved `moved` px on screen in this pass (negative: up). The thread is
  /// drawn back by that and chases home, drawn down at most `below` px (what may lie under the
  /// bottom stack: the room under the last row and a line, VirtualTranscript); the rest moves at
  /// once. `held` keeps to `below` in every arm (Jump to latest just landed). False when it moved at
  /// once (motion off, nothing to move). `arrived`: the move is a row that came, not the reply's own
  /// growth, and holds back up to CHASE_ARRIVAL_HOLD_LINES.
  shift(thread: HTMLElement | null, moved: number, below?: number, held?: boolean, arrived?: boolean): boolean;
  /// What may lie under the bottom stack is now `below` px: a chase drawn further down rests there.
  fit(below: number): void;
  /// How far the thread is drawn from its layout (px, positive: drawn down), 0 at rest.
  outstanding(): number;
  /// Ends the chase where the rows lay out.
  stop(): void;
  /// The reader took the view: the chase stops where the thread is drawn, so nothing moves but the
  /// reader's own scroll (a parked reader's view holds still, streaming-parked-still.test.ts). The
  /// thread stays drawn there until `resume` (followed again) or `stop`. `following`, when given, is
  /// asked once on the next display frame: input that left the view followed (a wheel or key at the
  /// bottom, which scrolls nothing and brings no later layout pass) goes on home from there.
  hold(following?: () => boolean): void;
  /// Followed again: a held chase goes on home from where it is drawn.
  resume(): void;
  /// The reader took the view while another motion of the thread (the composer growth's rise,
  /// VirtualTranscript `rowsMove`) still drew it `px` from its layout: that motion ends, and the chase
  /// draws the thread there instead, so it holds where it was painted (with `hold`) and goes home
  /// from there if the view is followed again (`resume`), in every arm: on the spring in `eased` and
  /// the chasing arms, in one frame in `instant`.
  carry(thread: HTMLElement, px: number): void;
  /// A held chase hands `px` of what it draws to the scroll offset (VirtualTranscript's quiet fold): the
  /// thread is drawn `px` nearer its layout, at once and with no frame loop; what is left stays held.
  /// False, and nothing changes, while its frame loop runs (it is not held).
  release(px: number): boolean;
  /// The turn ended: the chase lands at once when that frame, with what it already moved, stays within
  /// CHASE_LAND_LINES; else within BURST_S at no more than a line a frame (a snap of the whole trail
  /// moved the rows up to two lines in a frame, and a snap on top of a frame that had moved, 26-40 px).
  land(): void;
  /// Other motion that moves the rows the chase moves, on Web Animations (the turn's end fold,
  /// turnEndFold.ts): each of the chase's frames reads how far they move the rows in that frame, on
  /// the same clock, and moves at most what is left of ARRIVAL_FRAME_LINES (`alongsideMove`). Kept
  /// until replaced; animations that ended move nothing.
  alongside(animations: ReadonlySet<Animation> | undefined): void;
};

/// What `alongsideMove` reads of one animation once: how far its keyframes move a row's `translate`
/// (px, the y span) and its easing.
type Slide = { span: number; ease: (progress: number) => number };
const slides = new WeakMap<Animation, Slide | null>();
const NAMED_EASES: Record<string, readonly [number, number, number, number]> = {
  ease: [0.25, 0.1, 0.25, 1],
  "ease-in": [0.42, 0, 1, 1],
  "ease-out": [0, 0, 0.58, 1],
  "ease-in-out": [0.42, 0, 0.58, 1],
};
function slideOf(animation: Animation): Slide | null {
  const known = slides.get(animation);
  if (known !== undefined) return known;
  const effect = animation.effect as KeyframeEffect | null;
  const ys = (effect?.getKeyframes?.() ?? [])
    .map((frame) => (typeof frame.translate === "string" ? frame.translate : undefined))
    .filter((value): value is string => value !== undefined)
    .map((value) => (value === "none" ? 0 : Number.parseFloat(value.trim().split(/\s+/)[1] ?? "0")))
    .filter(Number.isFinite);
  let slide: Slide | null = null;
  if (ys.length > 1) {
    const easing = (effect?.getTiming().easing ?? "linear").trim();
    const curve = parseBezier(easing) ?? NAMED_EASES[easing];
    slide = {
      span: Math.max(...ys) - Math.min(...ys),
      // A curve this cannot read (steps()) may move its whole span in any frame.
      ease: easing === "linear" ? (p) => p : curve ? (p) => bezierAt(curve, p) : (p) => (p > 0 ? 1 : 0),
    };
  }
  slides.set(animation, slide);
  return slide;
}

/// How far `animations` move a row in the display frame at `now` (the document timeline's time, which
/// a frame callback gets and the animations are drawn at), from the frame `dt` s before: the most any
/// one of them moves, from each one's own timing and easing, with no style or layout read. One still
/// waiting for its start time (it starts in this frame or the next) counts its first `dt`. O(animations).
export function alongsideMove(animations: Iterable<Animation> | undefined, dt: number): number {
  let most = 0;
  for (const animation of animations ?? []) {
    if (animation.playState === "idle" || animation.playState === "finished" || animation.playState === "paused")
      continue;
    const slide = slideOf(animation);
    if (!slide || slide.span < 0.5) continue;
    const timing = animation.effect?.getComputedTiming();
    const duration = typeof timing?.duration === "number" ? timing.duration : 0;
    if (!(duration > 0)) continue;
    const delay = timing?.delay ?? 0;
    const local = typeof timing?.localTime === "number" ? timing.localTime : 0;
    const pending = animation.startTime === null;
    const to = pending ? local + dt * 1000 : local;
    const from = to - dt * 1000;
    const at = (time: number) => slide.ease(Math.min(1, Math.max(0, (time - delay) / duration)));
    most = Math.max(most, slide.span * Math.abs(at(to) - at(from)));
  }
  return most;
}

/// The host's motion speed as a factor of the standard step (`--agent-motion-move`), 0 with motion
/// off, Reduce Motion or a hidden page.
function speedOf(node: HTMLElement): number {
  const doc = node.ownerDocument;
  if (motionMode(doc) !== "full") return 0;
  const token = cssTimeMs(doc.defaultView?.getComputedStyle(node).getPropertyValue("--agent-motion-move") ?? "");
  return token === undefined ? 1 : token / MOTION_MS.standard;
}

/// Whether an arrival comes home on the arrival step: the shipped look. The gallery's and the
/// harness's earlier looks (`data-tail-glide` quick, glide, jump: tailGlide.ts) keep the spring.
function arrivalLook(node: HTMLElement): boolean {
  const look = node.closest("[data-tail-glide]")?.getAttribute("data-tail-glide");
  return !look || look === "arrive";
}

/// The trail bound (px): CHASE_MAX_TRAIL_LINES of the chat's lines.
export function chaseMaxTrail(): number {
  return CHASE_MAX_TRAIL_LINES * currentChatMetrics().lineHeight;
}

export function createFollowChase(arm: FollowMotionArm): FollowChase {
  let thread: HTMLElement | null = null;
  /// Drawn offset (px, positive: down) and its speed (px/s).
  let x = 0;
  let v = 0;
  /// The fixed-duration arm: the segment in flight (from, elapsed s, duration s).
  let chunk = { from: 0, at: 0, duration: CHUNK_S };
  /// A row that arrived: the arrival step in flight (from px, elapsed s, duration s), on ARRIVAL_EASE
  /// to 0 at its end. Anything else that moves the rows (the reply's growth, `land`, `hold`) hands
  /// it back to the spring from where it is drawn and how fast it goes.
  let arrival: { from: number; at: number; duration: number } | undefined;
  let frame: number | undefined;
  /// When the pending `frame` was asked for (performance.now ms).
  let askedAt = 0;
  /// The page drew no frame for FRAMELESS_MS: moves land at once until a frame runs again.
  let frameless = false;
  /// A send's rows, or anything in the `blocks` arm: it may pass under the glass composer while it
  /// settles, so `below` holds nothing back (the trail bound still does). Set by each `shift`: a
  /// finite `below` after a send keeps to it again.
  let rising = false;
  /// `hold(following)`: the one frame that asks whether the view is still followed.
  let recheck: number | undefined;
  const cancelRecheck = () => {
    if (recheck !== undefined) thread?.ownerDocument.defaultView?.cancelAnimationFrame(recheck);
    recheck = undefined;
  };
  let last: number | undefined;
  let scale = 1;
  /// While the trail is past its bound: the speed (px/s) that brings it back within BURST_S of the
  /// landing that put it there, 0 inside the bound.
  let burst = 0;
  /// When (ms, the frame clock) the trail must be back within its bound: BURST_S after the landing
  /// that first put it past, kept while more lands before then.
  let due: number | undefined;
  /// `land`: home within BURST_S whatever the trail, nothing more to chase.
  let landing = false;
  /// What `shift` moved at once since the last step (px): that display frame's step moves less by
  /// it, so the frame keeps to CHASE_LAND_LINES (a line in a burst).
  let spent = 0;
  /// How far the last display frame moved the rows so far (px): its step and what moved at once
  /// before it. A landing in the same frame as that step moves at once less by it (a commit lands
  /// before the frame's step, after it in the frame's measuring pass, or both: counting only the
  /// step moved one frame of the send 34.5 px, its landings before and after the step together).
  let stepped = 0;
  /// Other motion on the rows (`alongside`): the turn's end fold.
  let along: ReadonlySet<Animation> | undefined;
  /// What a frame `dt` s long may still move after that motion's own move in it (px): the fold keeps
  /// each frame to ARRIVAL_FRAME_LINES, and the reply's last lines draining on the chase moved on top
  /// of it, the two summed past the two thirds of a line no transition's frame may move (the fold's
  /// first frame 11.5 px and the drain's 3.8 px: 15.3 px, turn-transition-jumps `thought-text` end).
  /// Infinite with nothing else moving.
  const leftBeside = (dt: number, slots: number) => {
    if (!along?.size) return Number.POSITIVE_INFINITY;
    const other = alongsideMove(along, dt);
    return other > 0
      ? Math.max(0, ARRIVAL_FRAME_LINES * currentChatMetrics().lineHeight * slots - other)
      : Number.POSITIVE_INFINITY;
  };
  /// While it chases the thread is its own compositor layer, so a frame's step moves it without
  /// painting its rows again (a `translate` on an unpromoted thread repainted every row each frame).
  const draw = () => {
    if (!thread) return;
    if (x === 0) {
      thread.style.removeProperty("translate");
      thread.style.removeProperty("will-change");
    } else {
      thread.style.willChange = "translate";
      thread.style.translate = `0 ${x}px`;
    }
    // The live line held at the bottom moves against the thread in the same frame (pinnedLiveLine.ts).
    drawPinned(thread, x);
  };
  const stop = () => {
    cancelRecheck();
    if (frame !== undefined) thread?.ownerDocument.defaultView?.cancelAnimationFrame(frame);
    frame = undefined;
    last = undefined;
    x = 0;
    v = 0;
    burst = 0;
    due = undefined;
    rising = false;
    landing = false;
    spent = 0;
    stepped = 0;
    arrival = undefined;
    draw();
  };
  const step = (now: number) => {
    frame = undefined;
    // This frame came FRAMELESS_MS or more after it was asked for: the page drew nothing meanwhile
    // (covered by another workspace), so nobody saw the chase start. It lands before this frame
    // paints instead of sliding in from where it was held: one block that arrived while away, with
    // nothing after it to move the rows, drew 79 px off on the first frame back (#41252).
    if (performance.now() - askedAt >= FRAMELESS_MS) {
      stop();
      return;
    }
    const dt = last === undefined ? 1 / 120 : Math.min(MAX_STEP_S, Math.max(0, (now - last) / 1000));
    last = now;
    const from = x;
    // Past CATCH_UP_LINES behind (a burst faster than the limit) the limit rises by what is further
    // behind over CATCH_UP_S, so a frame never moves far while the view stays near the newest line.
    const line = currentChatMetrics().lineHeight;
    const catchUp = CATCH_UP_LINES * line;
    // A burst brings the trail back within its bound and on to a line (`drain`), so the next block
    // that lands has room under the bound instead of starting another burst at once.
    const drain = landing ? Math.abs(x) : Math.max(0, Math.abs(x) - catchUp);
    if (!(burst > 0 && drain > 0)) {
      burst = 0;
      due = undefined;
    }
    // Past the trail bound the chase moves at least `burst`, and no frame more than a line.
    const fastest = (CHASE_MAX_FRAME_LINES * line) / (1 / 120);
    const limit = Math.min(
      fastest,
      Math.max(burst, (CHASE_MAX_SPEED + Math.max(0, Math.abs(x) - catchUp) / CATCH_UP_S) / Math.max(scale, 0.25)),
    );
    if (arrival) {
      // The arrival step: its curve to its last frame, which draws the rows home (and stops).
      arrival.at += dt;
      const progress = Math.min(1, arrival.at / arrival.duration);
      const nextX = arrival.from * (1 - arrivalEase(progress));
      v = (nextX - x) / Math.max(dt, 1e-3);
      x = progress >= 1 ? 0 : nextX;
      spent = 0;
      if (x === 0) {
        stop();
        return;
      }
      stepped = Math.abs(x - from);
      draw();
      askedAt = performance.now();
      frame = thread?.ownerDocument.defaultView?.requestAnimationFrame(step);
      return;
    } else if (arm === "instant") {
      // At once, as every move in this arm: what another motion left with the chase (`carry`, the
      // composer growth's rise the reader froze) lands in the first frame it goes home in.
      x = 0;
      v = 0;
    } else if (arm === "spring" || arm === "blocks" || arm === "eased") {
      // Critically damped toward 0, exact over the step: x(t) = (x0 + (v0 + w x0) t) e^(-w t).
      // The `eased` arm chases nothing of its own (followGlide.ts moves its rows); what it holds is
      // only what `carry` handed it, which springs home as in the default arm (it fell through to
      // the `linear` approach below before).
      const w = (2 * Math.PI) / (RESPONSE_S * scale);
      const decay = Math.exp(-w * dt);
      const carry = v + w * x;
      let nextX = (x + carry * dt) * decay;
      let nextV = (v - w * carry * dt) * decay;
      // No frame moves more than the speed limit allows, nor more than a line a 120 Hz slot (`cap`,
      // which the burst below keeps to as well: no path moves a frame further).
      const slots = Math.max(1, Math.round(dt * 120));
      const frameMost = CHASE_MAX_FRAME_LINES * line * slots;
      // A frame that already moved at once keeps to CHASE_LAND_LINES in all, unless a burst is
      // bringing the trail back (those frames move up to a line in all, as before).
      // And with what other motion moves the rows in this frame (`alongside`), no more than its bound.
      const cap = Math.min(
        Math.max(0, (spent > 0 && !(burst > 0) ? Math.min(frameMost, CHASE_LAND_LINES * line) : frameMost) - spent),
        leftBeside(dt, slots),
      );
      const most = Math.min(limit * dt, cap);
      if (Math.abs(nextX - x) > most) {
        nextX = x + Math.sign(nextX - x) * most;
        nextV = Math.sign(nextV) * Math.min(Math.abs(nextV), limit);
      }
      // In a burst, at least its step (the spring from rest starts slower), as far as a line from
      // home: within that the chase keeps its own speed (the burst on to home moved the rows a line
      // a frame past where they needed to). Landing, all the way home.
      const floor = Math.min(drain, burst * dt, cap);
      if (Math.abs(nextX - x) < floor) {
        nextX = x - Math.sign(x) * floor;
        nextV = -Math.sign(x) * Math.min(burst, limit);
      }
      // Critically damped never crosses its rest; a clamp's rounding must not either.
      if (Math.sign(nextX) !== Math.sign(x) && x !== 0) nextX = nextV = 0;
      x = nextX;
      v = nextV;
    } else if (arm === "chunk") {
      chunk.at += dt;
      const progress = Math.min(1, chunk.at / (chunk.duration * scale));
      const nextX = chunk.from * (1 - progress) * (1 - progress);
      v = (nextX - x) / Math.max(dt, 1e-3);
      x = nextX;
    } else {
      // `linear`: a steady approach at the speed limit, then a stop.
      const most = Math.min(limit * dt, leftBeside(dt, Math.max(1, Math.round(dt * 120))));
      const nextX = Math.abs(x) <= most ? 0 : x - Math.sign(x) * most;
      v = (nextX - x) / Math.max(dt, 1e-3);
      x = nextX;
    }
    stepped = Math.abs(x - from) + spent;
    spent = 0;
    if (Math.abs(x) < REST_PX && Math.abs(v) < REST_SPEED) {
      stop();
      return;
    }
    draw();
    askedAt = performance.now();
    frame = thread?.ownerDocument.defaultView?.requestAnimationFrame(step);
  };
  /// Runs the frame loop again from where the thread is drawn (after `hold`, or for `land`).
  const resume = () => {
    cancelRecheck();
    if (x === 0 || frame !== undefined || !thread) return;
    const view = thread.ownerDocument.defaultView;
    const timeline = thread.ownerDocument.timeline?.currentTime;
    last = typeof timeline === "number" ? timeline : performance.now();
    askedAt = performance.now();
    frame = view?.requestAnimationFrame(step);
  };
  return {
    arm,
    outstanding: () => x,
    stop,
    hold(following) {
      cancelRecheck();
      if (frame !== undefined) thread?.ownerDocument.defaultView?.cancelAnimationFrame(frame);
      frame = undefined;
      last = undefined;
      v = 0;
      burst = 0;
      due = undefined;
      stepped = 0;
      arrival = undefined;
      if (x === 0) {
        stop();
        return;
      }
      if (!following || !thread) return;
      recheck = thread.ownerDocument.defaultView?.requestAnimationFrame(() => {
        recheck = undefined;
        if (following()) resume();
      });
    },
    resume,
    alongside(animations) {
      along = animations;
    },
    carry(node, px) {
      if (!(Math.abs(px) >= 0.01)) return;
      if (thread && thread !== node) stop();
      thread = node;
      x += px;
      v = 0;
      chunk = { from: x, at: 0, duration: CHUNK_S };
      arrival = undefined;
      draw();
    },
    release(px) {
      if (frame !== undefined || recheck !== undefined) return false;
      x -= px;
      // The `chunk` arm's curve goes on from what is left, not from what was handed over.
      chunk = { from: x, at: 0, duration: CHUNK_S };
      if (Math.abs(x) < REST_PX) stop();
      else draw();
      return true;
    },
    land() {
      const line = currentChatMetrics().lineHeight;
      // At once only when that frame, with what it already moved (`spent`, `stepped`), stays within
      // a landing frame's CHASE_LAND_LINES: a turn that settles quietly stops where it is drawn, and
      // nothing moves after it settles (agent-pane-stream-jitter). Otherwise not at once: the frame
      // the turn ends in has often moved already (the reply's last line landing, the chase's step),
      // and a snap of what is left on top of that moved the rows 26-40 px in one frame
      // (send-stream-motion). Nothing under the stack holds it back (`fit`), and it moves at least
      // the rest of the trail over BURST_S, no frame more than a line with what the frame moved.
      if (!thread || Math.abs(x) + spent + stepped <= CHASE_LAND_LINES * line) {
        stop();
        return;
      }
      landing = true;
      rising = true;
      arrival = undefined;
      burst = Math.min((CHASE_MAX_FRAME_LINES * line) / (1 / 120), Math.abs(x) / BURST_S);
      resume();
    },
    fit(below) {
      if (!rising && x > Math.max(0, below)) {
        x = Math.max(0, below);
        chunk = { from: x, at: 0, duration: CHUNK_S };
        if (x === 0) stop();
        else draw();
      }
    },
    shift(node, moved, below = Number.POSITIVE_INFINITY, held = false, arrived = false) {
      // A shell that opts out (`data-follow-glide="off"`, the gallery's and harnesses' before) steps.
      if (!node || !(Math.abs(moved) > 0.5) || arm === "instant" || node.closest(FOLLOW_GLIDE_OFF)) return false;
      const speed = speedOf(node);
      if (!(speed > 0)) {
        stop();
        return false;
      }
      if (thread && thread !== node) stop();
      // No frame ran since one was asked for FRAMELESS_MS ago: nobody sees the chase, so the rows
      // move at once, and what it held lands with them. One frame running again ends it.
      if (frameless || (frame !== undefined && performance.now() - askedAt >= FRAMELESS_MS)) {
        stop();
        thread = node;
        if (!frameless) {
          frameless = true;
          node.ownerDocument.defaultView?.requestAnimationFrame(() => {
            frameless = false;
          });
        }
        return false;
      }
      thread = node;
      landing = false;
      scale = speed;
      // Drawn back by the move: the rows stay where the reader saw them this frame (up to
      // CHASE_MAX_LAG of the view; only a whole screen landing moves at once).
      const most = CHASE_MAX_LAG * (node.parentElement?.parentElement?.clientHeight || 600);
      const trail = chaseMaxTrail();
      // A send's rows rise out from behind the composer (`below` unbounded). In the `blocks` arm
      // (the default) everything may pass under the glass composer while it settles, held only by
      // the trail bound; the `spring` arm keeps a line to `below`, the rest of it moving at once.
      // Each move says which it is: a finite `below` after a send's rise keeps to it again (a rise
      // kept to the chase's rest let later streamed text pass under the composer past the bound).
      rising = (arm === "blocks" && !held) || below === Number.POSITIVE_INFINITY;
      // Within the bound before this move, a block that lands past it starts a stretch of its own
      // with all of BURST_S (the last stretch's deadline moved it up to a line a frame, its time
      // already spent).
      if (Math.abs(x) <= chaseMaxTrail()) due = undefined;
      x = Math.max(-most, Math.min(most, rising ? most : Math.max(0, below), x - moved));
      // A reply's growth (`below` bounded: not a send's rise, not after Jump to latest) holds back
      // at most CHASE_HOLD_LINES; the frame it lands in moves the rest, up to CHASE_LAND_LINES less
      // what it already moved at once and the chase's last step, so the text above starts home as the block lands instead of the
      // whole block pushing the live line under it down and raising it again.
      if (arm === "blocks" && !held && below !== Number.POSITIVE_INFINITY && x > 0) {
        const line = currentChatMetrics().lineHeight;
        const hold = arrived ? CHASE_ARRIVAL_HOLD_LINES : CHASE_HOLD_LINES;
        const atOnce = Math.min(x - hold * line, CHASE_LAND_LINES * line - spent - stepped, leftBeside(1 / 120, 1));
        if (atOnce > 0) {
          x -= atOnce;
          spent += atOnce;
        }
      }
      // Past the trail bound: back within it BURST_S after the landing that first put it past
      // (more landing before then speeds it up), at no more than a line a frame.
      const timeline = node.ownerDocument.timeline?.currentTime;
      const at = typeof timeline === "number" ? timeline : performance.now();
      if (Math.abs(x) > trail) {
        due ??= at + (arrived ? ARRIVAL_BURST_S : BURST_S) * 1000;
        const left = Math.max(1 / 120, (due - at) / 1000);
        const fastest = (CHASE_MAX_FRAME_LINES * currentChatMetrics().lineHeight) / (1 / 120);
        burst = Math.min(fastest, Math.max(burst, (Math.abs(x) - trail) / left));
      }
      chunk = { from: x, at: 0, duration: CHUNK_S };
      // A row that arrived comes home on the arrival step, from where the thread is drawn now (a move
      // that comes during one starts a new step from there); anything else hands it to the spring.
      // A move during a step (the arrived row's measured height a pass later) keeps that step's end,
      // longer only as its frames need, so a second pass never starts the motion over.
      const left = arrival ? (arrival.duration - arrival.at) * 1000 : undefined;
      arrival =
        arrived && !held && (arm === "blocks" || arm === "spring") && x !== 0 && arrivalLook(node)
          ? { from: x, at: 0, duration: arrivalStepMs(x, scale, left) / 1000 }
          : undefined;
      draw();
      cancelRecheck();
      if (frame === undefined) {
        // Integrate from this frame's time: the first step lands one display frame on.
        const view = node.ownerDocument.defaultView;
        last = at;
        askedAt = performance.now();
        frame = view?.requestAnimationFrame(step);
      }
      return true;
    },
  };
}
