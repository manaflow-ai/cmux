/**
 * The files panel's open and close motion.
 *
 * The panel is a fixed-width layer pinned to the right edge of #content; the
 * diff column changes width once per toggle. To keep every animation frame
 * on the compositor, a toggle runs in two steps:
 *
 * 1. The layout change: `data-files-hidden` flips, so the (virtualized) diff
 *    reflows to its final width in this frame, while a hold animation keeps
 *    the panel exactly where it is on screen.
 * 2. Two frames later (after CodeView has re-rendered for its new width), a
 *    Web Animations transform animation moves the panel from that position
 *    to its target. Only `transform` changes on a promoted layer, so no
 *    animation frame lays out, recalculates style for, or paints the diff.
 *
 * Toggling again mid-way starts from the panel's current on-screen position,
 * so the motion reverses with no jump. The curve is the app's own spring
 * (`appear` to open, `disappear` to close, as for the cmux-next sidebar),
 * sampled from the spring's step response into keyframes. Reduced motion
 * switches the panel in one frame.
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

type MotionAnimation = Pick<Animation, "cancel" | "finished">;

type MotionPanel = Pick<HTMLElement, "animate" | "getBoundingClientRect"> & { dataset: DOMStringMap };

export type FilesPanelMotionHost = {
  /** The panel element (#files-sidebar), or null while it is not mounted. */
  panel: () => MotionPanel | null;
  /** Where `data-files-hidden` lives (document.body). */
  body: { dataset: DOMStringMap };
  /** The panel's current horizontal offset in px (0 open, its width closed). */
  currentOffset: (panel: MotionPanel) => number;
  requestFrame: (callback: () => void) => void;
  reducedMotion: () => boolean;
};

export type FilesPanelMotion = {
  /** Shows or hides the panel; `animate: false` applies it at once (boot). */
  set: (visible: boolean, options?: { animate?: boolean }) => void;
};

export function createFilesPanelMotion(host: FilesPanelMotionHost): FilesPanelMotion {
  let visible: boolean | null = null;
  let running: MotionAnimation | null = null;
  let generation = 0;

  const settle = (token: number, panel: MotionPanel) => {
    if (token === generation) {
      running = null;
      delete panel.dataset.filesMotion;
    }
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
      const from = panel != null && running != null ? host.currentOffset(panel) : next ? width : 0;
      running?.cancel();
      running = null;
      if (panel == null || first || options.animate === false || host.reducedMotion() || width <= 0) {
        host.body.dataset.filesHidden = next ? "false" : "true";
        if (panel != null) {
          delete panel.dataset.filesMotion;
        }
        return;
      }
      const target = next ? 0 : width;
      const hold = { transform: `translate3d(${from}px, 0, 0)` };
      // Step 1: the diff takes its final width now; the panel stays put and
      // stays painted (data-files-motion keeps it visible while it closes).
      panel.dataset.filesMotion = "running";
      running = panel.animate([hold, hold], { duration: 60_000, fill: "both" });
      host.body.dataset.filesHidden = next ? "false" : "true";
      // Step 2: after CodeView's resize render, the composited slide.
      host.requestFrame(() =>
        host.requestFrame(() => {
          if (token !== generation) {
            return;
          }
          const { durationMs, keyframes } = springSlideKeyframes(
            next ? MOTION_SPRINGS.appear : MOTION_SPRINGS.disappear,
            from,
            target,
          );
          const slide = panel.animate(keyframes, { duration: durationMs, easing: "linear" });
          running?.cancel();
          running = slide;
          slide.finished.then(
            () => settle(token, panel),
            () => undefined,
          );
        }),
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
