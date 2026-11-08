// Hover intent for every page (Leo, 2026-10-14: tooltips and hover cards showed at once on every
// control the pointer passed). The same policy as the native app's `HoverIntent`
// (Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/HoverIntent/HoverIntent.swift; a test reads that
// file and fails when the numbers drift): the first tooltip of a group waits, a neighbor's then
// shows at once while the group is warm, and the warmth cools a moment after the last one hid.
// Hover cards wait longer, and the safe triangle (`aimingAt`) keeps a card a pointer heads into.
import { useEffect, useMemo, useRef, useState } from "react";

/**
 * The timing, in ms. AppKit's tooltip waits `NSInitialToolTipDelay` (about 1000 ms at the default
 * setting). cmux waits 450 ms (Leo, 2026-10-14: 400-500): a pointer sweeping across a toolbar
 * button is on it for 30-100 ms, far under the delay, while a deliberate rest gets its answer in
 * under half a second. Mirrors `HoverIntentTiming.standard`.
 */
export const HOVER_INTENT = {
  /** Pointer rest before the first tooltip of a group shows. */
  tooltipDelay: 450,
  /** After the last tooltip hid, how long the next one still shows at once. */
  tooltipWarm: 500,
  /** Pointer rest on a row before its hover card shows. */
  cardDwell: 1000,
  /** How long a card stays after the pointer leaves its target and the card. */
  cardGrace: 200,
  /** How long a pointer heading for a shown card may pause on a target it crosses. */
  cardAim: 300,
} as const;

/** Pointer rest before an inline media preview starts. Kept separate from the native parity map. */
export const MEDIA_PREVIEW_DWELL = 250;

/** The timers the intent runs on; tests pass a fake one. */
export interface HoverClock {
  set(run: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

export const realClock: HoverClock = {
  set: (run, ms) => setTimeout(run, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/**
 * A warm group: while one of its intents shows, or for `warmFor` ms after the last one hid, the
 * next shows at once. One intent of the group shows at a time.
 */
export class HoverGroup {
  private active: HoverIntent<unknown> | null = null;
  /** Intents of the group waiting out their delay. */
  private readonly waiting = new Set<HoverIntent<unknown>>();
  private cooling: unknown;
  private hot = false;

  constructor(
    readonly warmFor: number = HOVER_INTENT.tooltipWarm,
    readonly clock: HoverClock = realClock,
  ) {}

  get warm() {
    return this.hot;
  }

  /** @internal */
  shown(by: HoverIntent<unknown>) {
    this.clock.clear(this.cooling);
    this.cooling = undefined;
    if (this.active && this.active !== by) this.active.hideNow();
    this.active = by;
    this.hot = true;
  }

  /** @internal */
  hidden(by: HoverIntent<unknown>) {
    if (this.active !== by) return;
    this.active = null;
    this.clock.clear(this.cooling);
    this.cooling = this.clock.set(() => {
      this.cooling = undefined;
      this.hot = false;
    }, this.warmFor);
  }

  /** @internal An intent of the group started or stopped waiting. */
  waits(by: HoverIntent<unknown>, waiting: boolean) {
    if (waiting) this.waiting.add(by);
    else this.waiting.delete(by);
  }

  /**
   * A click, a key or a scroll: what shows goes, what waits is dropped (a toolbar hint must not pop
   * up while typing), and the next one waits the full delay.
   */
  cool() {
    this.clock.clear(this.cooling);
    this.cooling = undefined;
    for (const intent of this.waiting) intent.cancelWait();
    this.active?.hideNow();
    this.active = null;
    this.hot = false;
  }
}

/** The pages' one tooltip group: title tooltips and toolbar hints warm each other. */
export const tooltipGroup = new HoverGroup();

export interface HoverIntentOptions<T> {
  /** `instant`: a warm group's (or a swap from one shown target to the next): no fade in. */
  show(target: T, instant: boolean): void;
  hide(target: T): void;
  /** Rest before the first shows (default: the tooltip delay). */
  delay?: number;
  group?: HoverGroup;
  clock?: HoverClock;
}

/**
 * Hover intent for one kind of target: `hover(target)` with what is under the pointer (null for
 * nothing). It shows after `delay`, at once while its group is warm; another target before then
 * restarts the wait, so a sweep shows nothing.
 */
export class HoverIntent<T> {
  private pending: T | null = null;
  private current: T | null = null;
  private timer: unknown;
  readonly group: HoverGroup;
  private readonly clock: HoverClock;

  constructor(private readonly options: HoverIntentOptions<T>) {
    this.group = options.group ?? new HoverGroup(HOVER_INTENT.tooltipWarm, options.clock);
    this.clock = options.clock ?? this.group.clock;
  }

  /** What shows now. */
  get shown(): T | null {
    return this.current;
  }

  /** The target under the pointer now; `delay` overrides the wait for this one (a keyboard caret). */
  hover(target: T | null, delay = this.options.delay ?? HOVER_INTENT.tooltipDelay) {
    if (target !== null && (target === this.current || (target === this.pending && delay > 0))) return;
    this.cancel();
    if (target === null) {
      const was = this.current;
      if (was === null) return;
      this.current = null;
      this.options.hide(was);
      this.group.hidden(this as HoverIntent<unknown>);
      return;
    }
    if (this.group.warm || delay <= 0) {
      this.showNow(target);
      return;
    }
    this.pending = target;
    this.group.waits(this as HoverIntent<unknown>, true);
    this.timer = this.clock.set(() => {
      this.timer = undefined;
      this.pending = null;
      this.group.waits(this as HoverIntent<unknown>, false);
      this.showNow(target);
    }, delay);
  }

  /** Puts it away and cools the group. */
  dismiss() {
    this.cancel();
    this.hideNow();
    this.group.cool();
  }

  /** Cancels any wait and hides at once, leaving the group as it is (unmount). */
  dispose() {
    this.cancel();
    const was = this.current;
    if (was === null) return;
    this.current = null;
    this.options.hide(was);
    this.group.hidden(this as HoverIntent<unknown>);
  }

  /** @internal Another intent of the group showed. */
  hideNow() {
    const was = this.current;
    this.current = null;
    if (was !== null) this.options.hide(was);
  }

  private showNow(target: T) {
    const was = this.current;
    // The first of a cold group fades in; a warm neighbor's, or a swap, is there at once.
    const instant = this.group.warm || was !== null;
    if (was !== null && was !== target) this.options.hide(was);
    this.current = target;
    this.group.shown(this as HoverIntent<unknown>);
    this.options.show(target, instant);
  }

  /** @internal The group cooled: drop any wait. */
  cancelWait() {
    this.cancel();
  }

  private cancel() {
    if (this.timer !== undefined) this.clock.clear(this.timer);
    this.timer = undefined;
    this.pending = null;
    this.group.waits(this as HoverIntent<unknown>, false);
  }
}

/**
 * React state for a `HoverIntent`: `shown` is the target that shows, `instant` whether it came at
 * once (a warm group's: no fade in). `hover(target)` from pointer enter/leave, `dismiss()` on press,
 * key or scroll.
 */
export function useHoverIntent<T>(options: { delay?: number; group?: HoverGroup; clock?: HoverClock } = {}) {
  const [state, setState] = useState<{ shown: T | null; instant: boolean }>({ shown: null, instant: false });
  const intent = useRef<HoverIntent<T> | null>(null);
  if (!intent.current)
    intent.current = new HoverIntent<T>({
      ...options,
      show: (target, instant) => setState({ shown: target, instant }),
      hide: () => setState({ shown: null, instant: false }),
    });
  useEffect(() => {
    const current = intent.current;
    return () => current?.dispose();
  }, []);
  const controller = intent.current;
  // Stable across renders, so memoized children keep their props.
  const actions = useMemo(
    () => ({
      hover: (target: T | null, delay?: number) => controller.hover(target, delay),
      dismiss: () => controller.dismiss(),
    }),
    [controller],
  );
  return { shown: state.shown, instant: state.instant, ...actions };
}

export type Point = { x: number; y: number };
type Rect = { left: number; right: number; top: number; bottom: number };

/** Whether `p` lies inside the triangle `a b c` (either winding). */
export function insideTriangle(p: Point, a: Point, b: Point, c: Point): boolean {
  const side = (from: Point, to: Point) => (to.x - from.x) * (p.y - from.y) - (to.y - from.y) * (p.x - from.x);
  const ab = side(a, b);
  const bc = side(b, c);
  const ca = side(c, a);
  return (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0);
}

/**
 * The safe triangle (`CGRect.isAimedAt` natively): whether the pointer, moving from `from` to `to`, heads
 * for `rect` (an open submenu or card): it lies inside it, or inside the triangle from `from` to its
 * nearest edge. A row it crosses on the way then doesn't swap the card out.
 */
export function aimingAt(from: Point | undefined, to: Point | undefined, rect: Rect | undefined): boolean {
  if (!from || !to || !rect || rect.right <= rect.left || rect.bottom <= rect.top) return false;
  if (from.x === to.x && from.y === to.y) return false;
  if (to.x >= rect.left && to.x <= rect.right && to.y >= rect.top && to.y <= rect.bottom) return true;
  const beside = from.x < rect.left || from.x > rect.right;
  const [a, b]: [Point, Point] = beside
    ? [
        { x: from.x < rect.left ? rect.left : rect.right, y: rect.top },
        { x: from.x < rect.left ? rect.left : rect.right, y: rect.bottom },
      ]
    : [
        { x: rect.left, y: from.y < rect.top ? rect.top : rect.bottom },
        { x: rect.right, y: from.y < rect.top ? rect.top : rect.bottom },
      ];
  return insideTriangle(to, from, a, b);
}

/** A pointer-safe bridge between a hover trigger and its portaled card. */
export type HoverBridgeRegion = "trigger" | "card";

export interface HoverBridgeOptions {
  /** Rest before the bridge opens. A keyboard focus passes zero. */
  dwell: number;
  /** Grace after the pointer leaves both surfaces and their connector. */
  grace: number;
  clock?: HoverClock;
  open(): void;
  close(): void;
}

/**
 * Keeps one hover card alive while the pointer crosses the gap to its portal. The bridge owns one
 * timer whose named stop condition is either the dwell completing or the pointer leaving the safe
 * union; callers do not need a separate open and close timer.
 */
export class HoverBridge {
  private readonly clock: HoverClock;
  private readonly trigger = new Set<HoverBridgeRegion>();
  private timer: unknown;
  private state: "idle" | "waiting" | "open" = "idle";
  private held = false;
  private triggerRect: Rect | undefined;
  private cardRect: Rect | undefined;
  private pointer: Point | undefined;

  constructor(private readonly options: HoverBridgeOptions) {
    this.clock = options.clock ?? realClock;
  }

  get open() {
    return this.state === "open";
  }

  enter(region: HoverBridgeRegion, rect: Rect | undefined, point?: Point, immediate = false): void {
    this.setRect(region, rect);
    this.pointer = point ?? this.pointer;
    this.trigger.add(region);
    if (this.state === "open") {
      this.clearTimer();
      return;
    }
    if (immediate || this.options.dwell <= 0) {
      this.clearTimer();
      return this.show();
    }
    // Keep an existing dwell while React moves from the trigger to the portal card. A prior
    // region callback may have left the state waiting without a timer; in that case re-arm it.
    if (this.state !== "waiting" || this.timer === undefined) {
      this.clearTimer();
      this.state = "waiting";
      this.timer = this.clock.set(() => {
        this.timer = undefined;
        if (this.trigger.has("trigger") || this.inSafeZone(this.pointer)) this.show();
        else this.state = "idle";
      }, this.options.dwell);
    }
  }

  leave(region: HoverBridgeRegion, rect: Rect | undefined, point?: Point): void {
    this.setRect(region, rect);
    this.pointer = point ?? this.pointer;
    this.trigger.delete(region);
    // Before the card opens there is no portal bridge to aim for. A pointer that is only a few
    // pixels outside the trigger must cancel the dwell, rather than inheriting the trigger's
    // padding and opening after the pointer has already left.
    if (this.state === "waiting" && region === "trigger" && !this.cardRect) {
      this.clearTimer();
      this.state = "idle";
      return;
    }
    if (this.held || this.trigger.size > 0 || this.inSafeZone(this.pointer)) return;
    if (this.state === "waiting") {
      this.clearTimer();
      this.state = "idle";
      return;
    }
    this.scheduleClose();
  }

  /** Tracks the gap between React's trigger/card pointer events. */
  move(point: Point): void {
    this.pointer = point;
    if (this.held) return;
    if (this.state === "waiting") {
      // Motion within the trigger is still deliberate hover; only motion outside the safe union
      // cancels the dwell.
      if (this.trigger.size > 0 || this.inSafeZone(point)) return;
      this.clearTimer();
      this.state = "idle";
      return;
    }
    if (this.trigger.size > 0 || this.state === "idle" || this.inSafeZone(point)) {
      this.clearTimer();
      return;
    }
    if (this.state === "open") this.scheduleClose();
  }

  /** Refreshes portal geometry while the pointer is in the connector gap. */
  update(rects: { trigger?: Rect; card?: Rect }): void {
    if ("trigger" in rects) this.triggerRect = rects.trigger;
    if ("card" in rects) this.cardRect = rects.card;
  }

  /** A menu opened by the card is an explicit hold until it closes. */
  hold(): void {
    this.held = true;
    this.clearTimer();
  }

  /** Re-evaluate the one close condition after an explicit hold ends. */
  release(): void {
    this.held = false;
    if (this.state === "open" && this.trigger.size === 0 && !this.inSafeZone(this.pointer)) this.scheduleClose();
  }

  stop(): void {
    this.clearTimer();
    this.trigger.clear();
    this.held = false;
    const wasOpen = this.state === "open";
    this.state = "idle";
    if (wasOpen) this.options.close();
  }

  private show(): void {
    this.clearTimer();
    if (this.state === "open") return;
    this.state = "open";
    this.options.open();
  }

  private scheduleClose(): void {
    if (this.held || this.timer !== undefined || this.state !== "open") return;
    this.timer = this.clock.set(() => {
      this.timer = undefined;
      // Stop condition: after grace, the pointer is outside both surfaces and their bridge.
      if (this.trigger.size === 0 && !this.inSafeZone(this.pointer)) {
        this.state = "idle";
        this.options.close();
      }
    }, this.options.grace);
  }

  private clearTimer(): void {
    if (this.timer !== undefined) this.clock.clear(this.timer);
    this.timer = undefined;
  }

  private setRect(region: HoverBridgeRegion, rect: Rect | undefined): void {
    const usable = validRect(rect) ? rect : undefined;
    if (region === "trigger") this.triggerRect = usable;
    else this.cardRect = usable;
  }

  private inSafeZone(point: Point | undefined): boolean {
    if (!point) return false;
    // A JSDOM element (and a detached portal during teardown) reports an all-zero
    // rect. It is not a safe zone: treating it as one makes a pointerdown at the
    // default (0, 0) look like it is still on a pinned card forever.
    const trigger = validRect(this.triggerRect) ? this.triggerRect : undefined;
    const card = validRect(this.cardRect) ? this.cardRect : undefined;
    if (containsRect(trigger, point, HOVER_BRIDGE_PADDING) || containsRect(card, point, HOVER_BRIDGE_PADDING))
      return true;
    if (!trigger || !card) return false;
    if (insideCorridor(point, trigger, card)) return true;
    const from = nearestPoint(trigger, card);
    const to = nearestPoint(card, trigger);
    return distanceToSegment(point, from, to) <= HOVER_BRIDGE_PADDING;
  }
}

/** How far outside the trigger, the card and their corridor the pointer may stray. */
const HOVER_BRIDGE_PADDING = 10;

/**
 * The gap between the trigger and the card, from the trigger's facing edge to the card's: a card
 * that opens above its trigger is reached across the band from the trigger's top edge to the
 * card's whole bottom edge, so a diagonal path to the card's far corner stays on it. The band
 * stops at the two facing edges; it never reaches past them into a neighboring row.
 */
function insideCorridor(point: Point, trigger: Rect, card: Rect): boolean {
  let edges: [Point, Point, Point, Point] | undefined;
  if (card.bottom <= trigger.top)
    edges = [
      { x: trigger.left, y: trigger.top },
      { x: trigger.right, y: trigger.top },
      { x: card.right, y: card.bottom },
      { x: card.left, y: card.bottom },
    ];
  else if (card.top >= trigger.bottom)
    edges = [
      { x: trigger.left, y: trigger.bottom },
      { x: trigger.right, y: trigger.bottom },
      { x: card.right, y: card.top },
      { x: card.left, y: card.top },
    ];
  else if (card.left >= trigger.right)
    edges = [
      { x: trigger.right, y: trigger.top },
      { x: trigger.right, y: trigger.bottom },
      { x: card.left, y: card.bottom },
      { x: card.left, y: card.top },
    ];
  else if (card.right <= trigger.left)
    edges = [
      { x: trigger.left, y: trigger.top },
      { x: trigger.left, y: trigger.bottom },
      { x: card.right, y: card.bottom },
      { x: card.right, y: card.top },
    ];
  if (!edges) return false;
  const [a, b, c, d] = edges;
  return insideTriangle(point, a, b, c) || insideTriangle(point, a, c, d);
}

function containsRect(rect: Rect | undefined, point: Point, padding: number): boolean {
  return Boolean(
    validRect(rect) &&
    point.x >= rect.left - padding &&
    point.x <= rect.right + padding &&
    point.y >= rect.top - padding &&
    point.y <= rect.bottom + padding,
  );
}

function validRect(rect: Rect | undefined): rect is Rect {
  return Boolean(
    rect &&
    Number.isFinite(rect.left) &&
    Number.isFinite(rect.top) &&
    Number.isFinite(rect.right) &&
    Number.isFinite(rect.bottom) &&
    rect.right > rect.left &&
    rect.bottom > rect.top,
  );
}

function nearestPoint(from: Rect, to: Rect): Point {
  const x =
    from.right < to.left
      ? from.right
      : from.left > to.right
        ? from.left
        : Math.max(from.left, Math.min((to.left + to.right) / 2, from.right));
  const y =
    from.bottom < to.top
      ? from.bottom
      : from.top > to.bottom
        ? from.top
        : Math.max(from.top, Math.min((to.top + to.bottom) / 2, from.bottom));
  return { x, y };
}

function distanceToSegment(point: Point, from: Point, to: Point): number {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  if (dx === 0 && dy === 0) return Math.hypot(point.x - from.x, point.y - from.y);
  const t = Math.max(0, Math.min(1, ((point.x - from.x) * dx + (point.y - from.y) * dy) / (dx * dx + dy * dy)));
  return Math.hypot(point.x - (from.x + t * dx), point.y - (from.y + t * dy));
}
