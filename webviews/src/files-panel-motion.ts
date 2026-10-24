import { isAgentMotionOff } from "./agent-session/shared/motion";
import { MOTION_MS } from "./motion/scale.generated";

/**
 * The files panel's open and close motion.
 *
 * The panel is a fixed-width layer pinned to the right edge of #content. A
 * toggle never lays out the diff in its own frame (plans/cmux-next/zero-latency.md,
 * rule g): the panel starts a composited Web Animations slide at once, and the
 * diff column changes width once per slide (`data-files-hidden` flips then).
 * Otherwise only `transform` changes during the slide.
 *
 * Nothing blank shows at any frame:
 * - opening, the diff keeps its full width under the panel until the end;
 * - closing, the diff takes its full width two frames in, under the panel that
 *   still covers that strip, so the slide uncovers real rows; for those two
 *   frames the curtain (a layer pinned where the panel's left edge rests,
 *   scaled on the compositor with the slide) covers what the panel uncovers.
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
 * The cmux-next motion springs the webviews use (this panel, the changes tree, the sync lists), at
 * speed "fast": MotionTunables.springDefaults (Packages/macOS/CmuxNext/Sources/CmuxNextDesign/
 * Motion/MotionTunables.swift), critically damped, so a move is visibly at rest within the motion
 * scale's standard step (180 ms). `appear` for sidebar show, `disappear` for sidebar hide.
 */
export const MOTION_SPRINGS = {
  move: { response: 0.15, dampingFraction: 1 },
  appear: { response: 0.135, dampingFraction: 1 },
  disappear: { response: 0.11, dampingFraction: 1 },
} as const satisfies Record<string, SpringParameters>;

/**
 * The cmux-next fade tokens the webviews use, in ms at speed "fast" (MotionTunables.fadeDefaults),
 * on the motion scale (MOTION_MS). Under Reduce Motion a fade is at most `crossfade` long: Swift's
 * crossfade, the scale's quick step (80 ms), as in design-tokens.json. `highlight` is a settled
 * row's long fade out (1.2 s), not a transition.
 */
export const MOTION_FADES = {
  hover: MOTION_MS.quick,
  fadeIn: MOTION_MS.micro,
  fadeOut: MOTION_MS.quick,
  crossfade: MOTION_MS.quick,
  highlight: 1200,
} as const;

/** Seconds until the spring reaches 95% of its travel (cmux-next `perceivedDuration`, Motion.duration(spring)). */
export function springPerceivedDuration(spring: SpringParameters): number {
  const step = 0.001;
  for (let t = 0; t < 5 * spring.response + 1; t += step) if (springStepResponse(spring, t) >= 0.95) return t;
  return 5 * spring.response;
}

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

  // The host can change `ui.animationSpeed` while a slide is in flight. CSS transitions are
  // covered by the root policy rule, but Web Animations need an explicit cancellation and the
  // panel must settle its layout state before the next paint. Observe the root once per controller
  // so a setting change cannot leave a canceled slide with stale motion markers or a narrow grid.
  const motionRoot = typeof document !== "undefined" ? document.documentElement : null;
  const motionObserver =
    motionRoot && typeof MutationObserver !== "undefined"
      ? new MutationObserver(() => {
          if (!isAgentMotionOff()) return;
          generation += 1;
          stop();
          const panel = host.panel();
          host.body.dataset.filesHidden = visible ? "false" : "true";
          if (panel != null) {
            delete panel.dataset.filesMotion;
            delete panel.dataset.filesMotionTarget;
          }
        })
      : null;
  motionObserver?.observe(motionRoot!, { attributes: true, attributeFilter: ["data-agent-motion"] });

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
      if (
        panel == null ||
        first ||
        options.animate === false ||
        host.reducedMotion() ||
        isAgentMotionOff() ||
        width <= 0
      ) {
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
      // A diff laid out beside the panel: the curtain covers what the panel uncovers. A diff at
      // full width is already under the panel everywhere.
      const curtain = host.body.dataset.filesHidden === "false" ? host.curtain?.() : null;
      const curtainSlide = curtain ? curtain.animate(curtainKeyframes(spring, from, target, width), timing) : null;
      if (curtainSlide) running.push(curtainSlide);
      const start = host.timelineTime?.() ?? null;
      if (start != null) for (const animation of running) animation.startTime = start;
      if (!next && curtainSlide) {
        // Closing: the diff takes its full width two frames in, while the panel still covers the
        // strip it grows into, so the slide uncovers real rows rather than the curtain's blank
        // fill. The click's own frame and the slide's first frame stay free of the reflow.
        host.requestFrame(() =>
          host.requestFrame(() => {
            if (token !== generation) return;
            host.body.dataset.filesHidden = resting;
            curtainSlide.cancel();
            running = running.filter((animation) => animation !== curtainSlide);
          }),
        );
      }
      slide.finished.then(
        () => {
          if (token !== generation) return;
          // An open's one reflow: the diff takes its new width in the frame the slide ends (a
          // close already took it two frames in).
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
