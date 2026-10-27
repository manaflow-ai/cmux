// AMBIENT-STEP (p14-energy-126): the ambient loops of a cmux page (every infinite CSS animation the
// person did not start: spinners, the working dot's breath, the shimmer, the running wave, the
// writing, recording, playing and mascot loops) draw AMBIENT_STEPS_PER_SECOND frames, not one per
// display refresh. Each loop stays the CSS animation its stylesheet declares, so Reduce Motion, the
// motion gate, Energy Saver, static indicators and a hidden page still remove it; under
// `data-cmux-ambient="step"` (WebTheme.swift, feature `pageAmbientSteps`) this module pauses it and
// seeks it on each tick of the page clock's ambient granularity. One aligned timer drives every loop
// of the page; it runs only while a loop is held and the page is active (ui/pageClock.ts), so a
// hidden page draws nothing.
//
// Chrome draws an animated image the same way: the compositor invalidates it when its next frame is
// due, never on every begin-frame (cc/paint/image_animation_controller.cc), and a CSS animation
// that runs on the compositor ticks every begin-frame (cc/animation/animation_host.cc). Transitions,
// entrances and loops the person starts (AMBIENT_EXEMPT_KEYFRAMES) keep the display's rate.
//
// Only a Chromium page steps. WebKit runs a transform or opacity loop in the render server, with no
// wake of the web content process or the app per frame; a script step would add those wakes.

import { type PageClock, pageClockFor } from "./pageClock";
import { SHARED_LOOP_KEYFRAMES, spinnerStartTime } from "./spinnerClock";
import { WAVE_KEYFRAMES } from "./wave";

/** On `<html>`: `step` makes the page's ambient loops step on the page clock. */
export const AMBIENT_ATTRIBUTE = "data-cmux-ambient";
/** The value of AMBIENT_ATTRIBUTE that turns stepping on. */
export const AMBIENT_STEP = "step";
/** On `<html>`: the engine that hosts the page (`webkit` from PageWebView+Pooled.swift). */
export const ENGINE_ATTRIBUTE = "data-engine";
/** The value of ENGINE_ATTRIBUTE on WebKit-hosted pages, which never step. */
export const WEBKIT_ENGINE = "webkit";

/** The loops held on the shared phase (Unix ms mod the period, ui/spinnerClock.ts) so loops on many
    rows, pages and the native chrome move as one: the shared loops and the running wave. Every other
    ambient loop keeps the phase it started on. */
export const SHARED_PHASE_KEYFRAMES: ReadonlySet<string> = new Set([...SHARED_LOOP_KEYFRAMES, WAVE_KEYFRAMES]);

/** Infinite loops the person starts and watches, which keep the display's rate: the New Tab edit
    mode's wiggle (newtab/screen.css), which follows the person as the native edit mode does. */
export const AMBIENT_EXEMPT_KEYFRAMES: ReadonlySet<string> = new Set(["nt-widget-wiggle"]);

/** The bits of a CSS animation the stepper reads and sets (a test passes a plain object). */
export interface AmbientAnimation {
  readonly animationName?: string;
  startTime: CSSNumberish | null;
  currentTime: CSSNumberish | null;
  readonly playState: string;
  pause(): void;
  play(): void;
  readonly effect: {
    readonly target?: { readonly isConnected: boolean } | null;
    getTiming(): { duration?: number | string | CSSNumericValue; iterations?: number };
  } | null;
}

/** The document timeline now and the Unix ms at which it read 0, for handing a loop back to the
    display's rate on the shared phase. */
export interface AmbientTimeline {
  readonly now: number;
  readonly origin: number;
}

/** `time` (Unix ms) mod `period`, in [0, period). */
export function ambientPhase(time: number, period: number): number {
  return ((time % period) + period) % period;
}

/** Whether `animation` is an ambient loop: a CSS animation that repeats forever and is not one the
    person starts (AMBIENT_EXEMPT_KEYFRAMES). */
export function isAmbientLoop(animation: AmbientAnimation): boolean {
  const name = animation.animationName;
  if (!name || AMBIENT_EXEMPT_KEYFRAMES.has(name)) return false;
  return animation.effect?.getTiming().iterations === Number.POSITIVE_INFINITY;
}

function loopPeriod(animation: AmbientAnimation): number | undefined {
  const duration = animation.effect?.getTiming().duration;
  return typeof duration === "number" && duration > 0 ? duration : undefined;
}

/** Draws a held loop on the step at `time` (Unix ms): on the shared phase when it has no offset,
    else at its own local time, `offset + time`. */
function seek(animation: AmbientAnimation, period: number, offset: number | undefined, time: number): void {
  animation.currentTime = offset === undefined ? ambientPhase(time, period) : offset + time;
}

/**
 * The page's held ambient loops and the one clock subscription that steps them. A loop is held from
 * `hold` until its CSS animation ends (the stylesheet removed it, or its element left the page) or
 * stepping turns off; the subscription exists only while a loop is held.
 */
export class AmbientStepper {
  /** Each held loop and its offset: its local time minus the step's Unix ms, or undefined for a loop
      on the shared phase. */
  private readonly held = new Map<AmbientAnimation, number | undefined>();
  private unsubscribe: (() => void) | undefined;

  constructor(
    private readonly clock: PageClock,
    /** Whether stepping is on (AMBIENT_ATTRIBUTE is `step`). */
    private readonly enabled: () => boolean,
    /** The document timeline, for handing a loop back; undefined when there is none. */
    private readonly timeline: () => AmbientTimeline | undefined,
  ) {}

  /** How many loops the stepper holds. */
  get size(): number {
    return this.held.size;
  }

  /** Whether the stepper is subscribed to the page clock. */
  get ticking(): boolean {
    return this.unsubscribe !== undefined;
  }

  /** Pauses `animation` on the current step and holds it; true if it holds it (stepping on, an
      ambient loop with a period). */
  hold(animation: AmbientAnimation): boolean {
    if (this.held.has(animation)) return true;
    if (!this.enabled() || !isAmbientLoop(animation)) return false;
    const period = loopPeriod(animation);
    if (period === undefined) return false;
    const time = this.clock.periodStart("ambient");
    let offset: number | undefined;
    if (!SHARED_PHASE_KEYFRAMES.has(animation.animationName ?? "")) {
      // A loop with its own phase goes on from where it is (a pending one from its start).
      const local = animation.currentTime;
      offset = (typeof local === "number" ? local : 0) - time;
    }
    animation.pause();
    seek(animation, period, offset, time);
    this.held.set(animation, offset);
    this.unsubscribe ??= this.clock.subscribe("ambient", this.step);
    return true;
  }

  /** Hands every held loop back to the display's rate and stops the clock: a shared loop on the
      shared phase, any other from the step it shows. */
  releaseAll(): void {
    const timeline = this.timeline();
    for (const [animation, offset] of this.held) this.release(animation, offset, timeline);
    this.held.clear();
    this.stopIfIdle();
  }

  private release(
    animation: AmbientAnimation,
    offset: number | undefined,
    timeline: AmbientTimeline | undefined,
  ): void {
    if (!this.live(animation)) return;
    if (offset !== undefined) {
      animation.play();
      return;
    }
    const period = loopPeriod(animation);
    if (period === undefined || !timeline) return;
    // A resolved start time plays a paused animation (Web Animations "set the start time").
    animation.startTime = spinnerStartTime(timeline.now, timeline.origin, period);
  }

  private live(animation: AmbientAnimation): boolean {
    return animation.playState !== "idle" && animation.effect?.target?.isConnected !== false;
  }

  private readonly step = (): void => {
    if (!this.enabled()) {
      this.releaseAll();
      return;
    }
    const time = this.clock.periodStart("ambient");
    for (const [animation, offset] of this.held) {
      const period = loopPeriod(animation);
      if (period === undefined || !this.live(animation)) {
        this.held.delete(animation);
        continue;
      }
      // Something set its start time and played it again: hold it on the step.
      if (animation.playState !== "paused") animation.pause();
      seek(animation, period, offset, time);
    }
    this.stopIfIdle();
  };

  private stopIfIdle(): void {
    if (this.held.size > 0 || !this.unsubscribe) return;
    this.unsubscribe();
    this.unsubscribe = undefined;
  }
}

const installed = new WeakMap<Document, AmbientStepper>();

/** Once per document: every ambient loop that starts while stepping is on is held on the page clock,
 * the loops already running are taken when stepping turns on, and all are handed back when it turns
 * off. Install it after `installSpinnerClock` and `installWave` (desktop.ts), whose `animationstart`
 * listeners set each loop's start time and so play it: this one runs after them and pauses it. A
 * WebKit page (ENGINE_ATTRIBUTE, set at document start) never steps and gets no listener. */
export function installAmbientStep(doc: Document = document, clock: PageClock = pageClockFor()): AmbientStepper {
  const existing = installed.get(doc);
  if (existing) return existing;
  const root = doc.documentElement;
  if (root.getAttribute(ENGINE_ATTRIBUTE) === WEBKIT_ENGINE) {
    const inert = new AmbientStepper(
      clock,
      () => false,
      () => undefined,
    );
    installed.set(doc, inert);
    return inert;
  }
  const enabled = () => root.getAttribute(AMBIENT_ATTRIBUTE) === AMBIENT_STEP;
  const timeline = (): AmbientTimeline | undefined => {
    const now = doc.timeline?.currentTime;
    const origin = doc.defaultView?.performance.timeOrigin;
    return typeof now === "number" && typeof origin === "number" ? { now, origin } : undefined;
  };
  const stepper = new AmbientStepper(clock, enabled, timeline);
  installed.set(doc, stepper);
  const holdAll = (animations: readonly Animation[]) => {
    for (const animation of animations) stepper.hold(animation as unknown as AmbientAnimation);
  };
  doc.addEventListener(
    "animationstart",
    (event) => {
      const name = event.animationName;
      if (!enabled() || AMBIENT_EXEMPT_KEYFRAMES.has(name) || !(event.target instanceof Element)) return;
      // `subtree` reaches a loop drawn on a pseudo-element (`#status::before`); `hold` takes only
      // the ones that repeat forever.
      holdAll(
        event.target
          .getAnimations({ subtree: true })
          .filter((animation) => (animation as CSSAnimation).animationName === name),
      );
    },
    true,
  );
  let wasEnabled = enabled();
  if (wasEnabled) holdAll(doc.getAnimations());
  const view = doc.defaultView;
  if (!view) return stepper;
  // The theme sets the attribute on each apply (WebTheme bootstrap); only a change moves loops.
  new view.MutationObserver(() => {
    const on = enabled();
    if (on === wasEnabled) return;
    wasEnabled = on;
    if (on) holdAll(doc.getAnimations());
    else stepper.releaseAll();
  }).observe(root, { attributes: true, attributeFilter: [AMBIENT_ATTRIBUTE] });
  return stepper;
}
