/**
 * The files panel's open and close motion.
 *
 * The panel is a fixed-width layer pinned to the right edge of #content. A
 * toggle never lays out the diff in its own frame (plans/cmux-next/zero-latency.md,
 * rule g): the panel starts a composited Web Animations slide at once, and the
 * diff column changes width once, when the slide ends (`data-files-hidden`
 * flips then). Only `transform` changes during the slide, so no animation
 * frame lays out, recalculates style for, or paints the diff.
 *
 * Nothing blank shows at any frame:
 * - opening, the diff keeps its full width under the panel until the end;
 * - closing, the diff keeps its narrow width until the end, and the curtain (a
 *   layer pinned where the panel's left edge rests, scaled on the compositor
 *   with the slide) covers the strip the panel uncovers.
 *
 * Toggling again mid-way starts from the panel's current on-screen position,
 * so the motion reverses with no jump, and the diff stays at the width it has.
 * The curve is the app's own spring (`appear` to open, `disappear` to close,
 * as for the cmux-next sidebar), sampled from the spring's step response into
 * keyframes, so WebKit runs it in Core Animation at the display rate (120 Hz
 * included). Reduced motion switches the panel in one frame.
 */

/** A spring in SwiftUI terms (`.spring(response:dampingFraction:)`), mass 1. */
export type SpringParameters = { response: number; dampingFraction: number };

/**
 * The cmux-next motion tokens this panel uses, at speed "fast"
 * (Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Motion/MotionTunables.swift,
 * cmux-tui/crates/cmux-motion/src/spring.rs; plans/cmux-next/motion.md owns
 * the values): `appear` for sidebar show, `disappear` for sidebar hide.
 */
export const MOTION_SPRINGS = {
  appear: { response: 0.18, dampingFraction: 0.9 },
  disappear: { response: 0.15, dampingFraction: 0.9 },
} as const satisfies Record<string, SpringParameters>;

/** Closed-form position of a unit step (0 to 1, from rest) after `t` seconds. */
export function springStepResponse(spring: SpringParameters, t: number): number {
  if (t <= 0) {
    return 0;
  }
  const w = (2 * Math.PI) / Math.max(spring.response, 0.001);
  const z = Math.max(spring.dampingFraction, 0);
  if (z < 1) {
    const wd = w * Math.sqrt(1 - z * z);
    return 1 - Math.exp(-z * w * t) * (Math.cos(wd * t) + ((z * w) / wd) * Math.sin(wd * t));
  }
  if (z === 1) {
    return 1 - Math.exp(-w * t) * (1 + w * t);
  }
  const s = w * Math.sqrt(z * z - 1);
  const r1 = -z * w + s;
  const r2 = -z * w - s;
  return 1 - (r2 * Math.exp(r1 * t) - r1 * Math.exp(r2 * t)) / (r2 - r1);
}

/**
 * Seconds until the step stays within 0.5% of its target, the length a
 * viewer reads (cmux-motion `visible_end`, cmux-next `perceivedDuration`).
 */
export function springVisibleEnd(spring: SpringParameters): number {
  const step = 0.001;
  let lastOutside = 0;
  for (let t = 0; t < 5 * spring.response + 1; t += step) {
    if (Math.abs(1 - springStepResponse(spring, t)) >= 0.005) {
      lastOutside = t;
    }
  }
  return lastOutside + step;
}

/**
 * The spring as a timed ease-out: its visible length and its curve sampled
 * as `samples + 1` progress points (0 to exactly 1). The slide uses them as
 * linearly interpolated keyframes rather than a CSS `linear()` easing,
 * because WebKit hands multi-keyframe transform animations to Core Animation
 * (which runs them at the display rate), and both engines composite them.
 */
export function springCurve(spring: SpringParameters, samples = 24): { durationMs: number; progress: number[] } {
  const end = springVisibleEnd(spring);
  const progress: number[] = [];
  for (let index = 0; index <= samples; index += 1) {
    // The last sample lands exactly on the target (the spring is within 0.5%).
    const value = index === samples ? 1 : springStepResponse(spring, (end * index) / samples);
    progress.push(Math.round(value * 10_000) / 10_000);
  }
  return { durationMs: Math.round(end * 1000), progress };
}

/** Transform keyframes moving from `from` to `to` px along the spring curve. */
export function springSlideKeyframes(
  spring: SpringParameters,
  from: number,
  to: number,
): {
  durationMs: number;
  keyframes: Keyframe[];
} {
  const { durationMs, progress } = springCurve(spring);
  const keyframes = progress.map((value, index) => ({
    offset: index / (progress.length - 1),
    transform: `translate3d(${Math.round((from + (to - from) * value) * 100) / 100}px, 0, 0)`,
  }));
  return { durationMs, keyframes };
}

/** Curtain keyframes: its scaleX follows the panel's offset (`offset / width`) along the same curve. */
export function curtainKeyframes(spring: SpringParameters, from: number, to: number, width: number): Keyframe[] {
  const { progress } = springCurve(spring);
  return progress.map((value, index) => ({
    offset: index / (progress.length - 1),
    transform: `scaleX(${Math.round(((from + (to - from) * value) / width) * 10_000) / 10_000})`,
  }));
}

type MotionAnimation = Pick<Animation, "cancel" | "finished" | "startTime">;

type MotionPanel = Pick<HTMLElement, "animate" | "getBoundingClientRect"> & { dataset: DOMStringMap };
type MotionCurtain = Pick<HTMLElement, "animate">;

export type FilesPanelMotionHost = {
  /** The panel element (#files-sidebar), or null while it is not mounted. */
  panel: () => MotionPanel | null;
  /**
   * The curtain (#files-motion-curtain): a layer of the diff's background with the panel's
   * resting box, transform-origin at its left edge, under the panel. Null: no curtain.
   */
  curtain?: () => MotionCurtain | null;
  /** Where `data-files-hidden` lives (document.body). */
  body: { dataset: DOMStringMap };
  /** The panel's current horizontal offset in px (0 open, its width closed). */
  currentOffset: (panel: MotionPanel) => number;
  requestFrame: (callback: () => void) => void;
  reducedMotion: () => boolean;
  /**
   * The document timeline's current time (`document.timeline.currentTime`). When given, the panel
   * and the curtain start at that same time, so they move in lockstep from the first frame (two
   * animations left pending can start a frame apart under load, which opens a strip between them).
   */
  timelineTime?: () => number | null;
};

export type FilesPanelMotion = {
  /** Shows or hides the panel; `animate: false` applies it at once (boot). */
  set: (visible: boolean, options?: { animate?: boolean }) => void;
};

export function createFilesPanelMotion(host: FilesPanelMotionHost): FilesPanelMotion {
  let visible: boolean | null = null;
  let running: MotionAnimation[] = [];
  let generation = 0;

  const stop = () => {
    for (const animation of running) animation.cancel();
    running = [];
  };

  return {
    set(next, options = {}) {
      if (visible === next) {
        return;
      }
      const first = visible == null;
      visible = next;
      generation += 1;
      const token = generation;
      const panel = host.panel();
      const width = panel?.getBoundingClientRect().width ?? 0;
      // Where the panel is on screen now, before anything changes.
      const from = panel != null && running.length > 0 ? host.currentOffset(panel) : next ? width : 0;
      stop();
      const resting = next ? "false" : "true";
      if (panel == null || first || options.animate === false || host.reducedMotion() || width <= 0) {
        host.body.dataset.filesHidden = resting;
        if (panel != null) {
          delete panel.dataset.filesMotion;
          delete panel.dataset.filesMotionTarget;
        }
        return;
      }
      const target = next ? 0 : width;
      const spring = next ? MOTION_SPRINGS.appear : MOTION_SPRINGS.disappear;
      // The panel stays painted for the whole slide; the target is the toggle's visible state.
      panel.dataset.filesMotion = "running";
      panel.dataset.filesMotionTarget = next ? "open" : "closed";
      const { durationMs, keyframes } = springSlideKeyframes(spring, from, target);
      const timing = { duration: durationMs, easing: "linear", fill: "forwards" } as const;
      const slide = panel.animate(keyframes, timing);
      running = [slide];
      // The diff is narrow (laid out beside the panel) until the slide ends: the curtain covers
      // what the panel uncovers. A diff at full width is already under the panel everywhere.
      const curtain = host.body.dataset.filesHidden === "false" ? host.curtain?.() : null;
      if (curtain) running.push(curtain.animate(curtainKeyframes(spring, from, target, width), timing));
      const start = host.timelineTime?.() ?? null;
      if (start != null) for (const animation of running) animation.startTime = start;
      slide.finished.then(
        () => {
          if (token !== generation) return;
          // The one reflow: the diff takes its new width in the frame the slide ends.
          host.body.dataset.filesHidden = resting;
          delete panel.dataset.filesMotion;
          delete panel.dataset.filesMotionTarget;
          stop();
        },
        () => undefined,
      );
    },
  };
}

/** The panel's current translateX in px, read from its computed transform. */
export function computedTranslateX(element: Element): number {
  const transform = getComputedStyle(element).transform;
  if (!transform || transform === "none") {
    return 0;
  }
  const values = transform.match(/matrix(3d)?\(([^)]+)\)/);
  if (values == null) {
    return 0;
  }
  const numbers = values[2].split(",").map((value) => Number.parseFloat(value));
  return values[1] ? (numbers[12] ?? 0) : (numbers[4] ?? 0);
}
