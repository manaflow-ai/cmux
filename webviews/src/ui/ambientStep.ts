// AMBIENT-STEP (p14-energy-126): the ambient loops of a cmux page (spinners, the working dot's
// breath, the shimmer and the running wave) draw AMBIENT_STEPS_PER_SECOND frames, not one per
// display refresh. Each loop stays the CSS animation its stylesheet declares, so Reduce Motion, the
// motion gate, Energy Saver, static indicators and a hidden page still remove it; under
// `data-cmux-ambient="step"` (WebTheme.swift, feature `pageAmbientSteps`) this module pauses it and
// seeks it to the shared phase (Unix time mod its period, ui/spinnerClock.ts) on each tick of the
// page clock's ambient granularity. One aligned timer drives every loop of the page; it runs only
// while a loop is held and the page is active (ui/pageClock.ts), so a hidden page draws nothing.
//
// Chrome draws an animated image the same way: the compositor invalidates it when its next frame is
// due, never on every begin-frame (cc/paint/image_animation_controller.cc), and a CSS animation
// that runs on the compositor ticks every begin-frame (cc/animation/animation_host.cc). Transitions
// and entrances the person starts are not ambient and keep the display's rate.

import { type PageClock, pageClockFor } from "./pageClock";
import { SHARED_LOOP_KEYFRAMES, type SpinnerAnimation, spinnerStartTime } from "./spinnerClock";
import { WAVE_KEYFRAMES } from "./wave";

/** On `<html>`: `step` makes the page's ambient loops step on the page clock. */
export const AMBIENT_ATTRIBUTE = "data-cmux-ambient";
/** The value of AMBIENT_ATTRIBUTE that turns stepping on. */
export const AMBIENT_STEP = "step";

/** Every keyframes name this module steps: the shared loops and the running wave. */
export const AMBIENT_KEYFRAMES: ReadonlySet<string> = new Set([...SHARED_LOOP_KEYFRAMES, WAVE_KEYFRAMES]);

/** The bits of a CSS animation the stepper reads and sets (a test passes a plain object). */
export type AmbientAnimation = SpinnerAnimation & {
  currentTime: CSSNumberish | null;
  readonly playState: string;
  pause(): void;
  readonly effect:
    | ({ readonly target?: { readonly isConnected: boolean } | null } & NonNullable<SpinnerAnimation["effect"]>)
    | null;
};

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

function loopPeriod(animation: AmbientAnimation): number | undefined {
  const duration = animation.effect?.getTiming().duration;
  return typeof duration === "number" && duration > 0 ? duration : undefined;
}

/**
 * The page's held ambient loops and the one clock subscription that steps them. A loop is held from
 * `hold` until its CSS animation ends (the stylesheet removed it, or its element left the page) or
 * stepping turns off; the subscription exists only while a loop is held.
 */
export class AmbientStepper {
  private readonly held = new Set<AmbientAnimation>();
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

  /** Pauses `animation` on the current step and holds it; true if it took it (stepping on, an
      ambient loop with a period). */
  hold(animation: AmbientAnimation): boolean {
    if (!this.enabled() || !animation.animationName || !AMBIENT_KEYFRAMES.has(animation.animationName)) return false;
    const period = loopPeriod(animation);
    if (period === undefined) return false;
    animation.pause();
    animation.currentTime = ambientPhase(this.clock.periodStart("ambient"), period);
    this.held.add(animation);
    this.unsubscribe ??= this.clock.subscribe("ambient", this.step);
    return true;
  }

  /** Hands every held loop back to the display's rate on the shared phase and stops the clock. */
  releaseAll(): void {
    const timeline = this.timeline();
    for (const animation of this.held) this.release(animation, timeline);
    this.held.clear();
    this.stopIfIdle();
  }

  private release(animation: AmbientAnimation, timeline: AmbientTimeline | undefined): void {
    const period = loopPeriod(animation);
    if (period === undefined || !timeline || !this.live(animation)) return;
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
    for (const animation of this.held) {
      const period = loopPeriod(animation);
      if (period === undefined || !this.live(animation)) {
        this.held.delete(animation);
        continue;
      }
      // Something set its start time and played it again: hold it on the step.
      if (animation.playState !== "paused") animation.pause();
      animation.currentTime = ambientPhase(time, period);
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
 * listeners set each loop's start time and so play it: this one runs after them and pauses it. */
export function installAmbientStep(doc: Document = document, clock: PageClock = pageClockFor()): AmbientStepper {
  const existing = installed.get(doc);
  if (existing) return existing;
  const root = doc.documentElement;
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
      if (!enabled() || !AMBIENT_KEYFRAMES.has(event.animationName) || !(event.target instanceof Element)) return;
      // `subtree` reaches a loop drawn on a pseudo-element (`#status::before`).
      holdAll(event.target.getAnimations({ subtree: true }));
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
