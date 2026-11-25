// TWO-FINGER BACK / FORWARD over an app page (Leo's brief, item 2): the pure decision. The host
// forwards each phase-aware trackpad scroll event it sees over the page (`cmux.page.swipe`,
// PageSwipeForwarder.swift) and decides nothing; this machine decides whether a gesture is a swipe,
// follows the fingers while it is one, and says on the lift whether it goes Back or Forward (the
// product's Go Back / Go Forward, never chat-message switching or browser history).
//
// The rules mirror the browser tabs' native swipe (BrowserSwipeGesture.swift): a 6 pt slop, the
// horizontal travel 1.5 times the vertical, a vertical or diagonal gesture declined, momentum never
// starting a swipe, a new `began` resetting. Past that: progress follows the fingers (travel / page
// width), a side with no entry rubber-bands and never commits, reversing past the start cancels, and
// the lift commits past a third of the width or on a quick flick the way it started.

export type SwipePhase = "mayBegin" | "began" | "changed" | "ended" | "cancelled";
export type SwipeDirection = "back" | "forward";

/** One trackpad scroll event as the host forwards it. */
export interface SwipeEvent {
  /** The host's number for the gesture (a release names it). */
  g?: number;
  phase: SwipePhase;
  /** From the momentum train after the lift (NSEvent `momentumPhase`), not the fingers. */
  momentum: boolean;
  /** NSEvent `scrollingDeltaX` / `scrollingDeltaY`, in points. */
  dx: number;
  dy: number;
  /** NSEvent `isDirectionInvertedFromDevice` (natural scrolling); true when absent. */
  inverted?: boolean;
  /** Milliseconds. */
  time: number;
  /** On `began`: whether Go Back / Go Forward has somewhere to go now. */
  back?: boolean;
  forward?: boolean;
}

export interface SwipeContext {
  /** The page's width in points: a full-width travel is progress 1. */
  width: number;
  /** Whether the element under the fingers keeps a horizontal gesture going that way (probe.ts). */
  keeps(direction: SwipeDirection): boolean;
  /** Where an interrupted spring-back had the content (signed progress, + is Back). */
  carry?: number;
}

export const SWIPE = {
  slop: 6,
  dominance: 1.5,
  /** Progress at which letting go navigates (AppKit ends a swipe past about a third). */
  commit: 0.3,
  /** A flick: progress per second the way the swipe started, past a small distance. */
  flickVelocity: 1.5,
  flickMin: 0.08,
  /** How far a side with no entry stretches at most. */
  rubber: 0.1,
  /** Fingers resting this long (ms) before the lift carry no velocity. */
  stale: 80,
} as const;

export type SwipeStep =
  | { kind: "none" }
  | { kind: "track"; direction: SwipeDirection; progress: number; available: boolean; armed: boolean }
  | { kind: "commit"; direction: SwipeDirection }
  | { kind: "cancel"; direction: SwipeDirection; progress: number };

export type SwipeMode = "idle" | "pending" | "tracking" | "declined";

const NONE: SwipeStep = { kind: "none" };

/** A dampened stretch that approaches `limit` and never reaches it. */
export function rubberBand(x: number, limit: number = SWIPE.rubber): number {
  return x <= 0 ? 0 : limit * (1 - 1 / (x / limit + 1));
}

export class SwipeGesture {
  mode: SwipeMode = "idle";
  direction: SwipeDirection | null = null;
  available = { back: false, forward: false };
  /** Finger travel (+ toward Back) and vertical travel since `began`. */
  private travel = 0;
  private vertical = 0;
  private base = 0;
  private raw = 0;
  private velocity = 0;
  private lastTime = 0;
  private carry = 0;

  feed(event: SwipeEvent, ctx: SwipeContext): SwipeStep {
    if (event.momentum) return NONE;
    switch (event.phase) {
      case "began": {
        const step = this.abort();
        if (event.back !== undefined) this.available.back = event.back;
        if (event.forward !== undefined) this.available.forward = event.forward;
        this.mode = "pending";
        this.direction = null;
        this.travel = 0;
        this.vertical = 0;
        this.velocity = 0;
        this.lastTime = event.time;
        this.carry = ctx.carry ?? 0;
        const moved = this.move(event, ctx);
        return step.kind === "none" ? moved : step;
      }
      case "changed":
        return this.move(event, ctx);
      case "ended":
        return this.end(event);
      case "mayBegin":
      case "cancelled": {
        const step = this.abort();
        this.mode = "idle";
        return step;
      }
    }
  }

  /** The progress shown: clamped on a side with an entry, rubber-banded on one without. */
  private display(): number {
    return this.isAvailable() ? Math.min(Math.max(this.raw, 0), 1) : rubberBand(this.raw);
  }

  private isAvailable(): boolean {
    return this.direction !== null && this.available[this.direction];
  }

  private abort(): SwipeStep {
    if (this.mode !== "tracking" || !this.direction) return NONE;
    const step: SwipeStep = { kind: "cancel", direction: this.direction, progress: this.display() };
    this.mode = "idle";
    return step;
  }

  private move(event: SwipeEvent, ctx: SwipeContext): SwipeStep {
    const fingers = event.inverted === false ? -event.dx : event.dx;
    this.travel += fingers;
    this.vertical += event.dy;
    if (this.mode === "pending") return this.decide(ctx);
    if (this.mode !== "tracking" || !this.direction) return NONE;
    const before = this.raw;
    this.raw = this.progressOf(ctx.width);
    // Back past where it started: the swipe is over, the rest of the gesture is the page's.
    if (this.raw <= 0) {
      const step: SwipeStep = { kind: "cancel", direction: this.direction, progress: 0 };
      this.mode = "declined";
      return step;
    }
    const dt = (event.time - this.lastTime) / 1000;
    if (dt > 0) this.velocity = 0.5 * this.velocity + 0.5 * ((this.raw - before) / dt);
    this.lastTime = event.time;
    return this.track();
  }

  private decide(ctx: SwipeContext): SwipeStep {
    const across = Math.abs(this.travel);
    const down = Math.abs(this.vertical);
    if (down >= SWIPE.slop && down * SWIPE.dominance > across) {
      this.mode = "declined";
      return NONE;
    }
    if (across < SWIPE.slop) return NONE;
    if (across < SWIPE.dominance * down) {
      this.mode = "declined";
      return NONE;
    }
    const direction: SwipeDirection = this.travel > 0 ? "back" : "forward";
    if (ctx.keeps(direction)) {
      this.mode = "declined";
      return NONE;
    }
    this.mode = "tracking";
    this.direction = direction;
    const sign = direction === "back" ? 1 : -1;
    this.base = Math.sign(this.carry) === sign && this.available[direction] ? Math.abs(this.carry) : 0;
    this.raw = this.progressOf(ctx.width);
    return this.track();
  }

  private progressOf(width: number): number {
    const sign = this.direction === "back" ? 1 : -1;
    return this.base + (sign * this.travel) / Math.max(width, 1);
  }

  private track(): SwipeStep {
    const direction = this.direction ?? "back";
    const available = this.isAvailable();
    return {
      kind: "track",
      direction,
      progress: this.display(),
      available,
      armed: available && this.raw >= SWIPE.commit,
    };
  }

  private end(event: SwipeEvent): SwipeStep {
    if (this.mode !== "tracking" || !this.direction) {
      this.mode = "idle";
      return NONE;
    }
    this.mode = "idle";
    const velocity = event.time - this.lastTime > SWIPE.stale ? 0 : this.velocity;
    const far = this.raw >= SWIPE.commit;
    const flick = velocity >= SWIPE.flickVelocity && this.raw >= SWIPE.flickMin;
    if (this.isAvailable() && velocity > -SWIPE.flickVelocity && (far || flick)) {
      return { kind: "commit", direction: this.direction };
    }
    return { kind: "cancel", direction: this.direction, progress: this.display() };
  }
}
