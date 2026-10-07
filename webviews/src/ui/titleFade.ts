// A clipped single-line title fades out at its end instead of ending in an ellipsis, and on hover
// (or keyboard focus) scrolls once to show its end: the web port of cmux-next's TitleFadeGeometry
// and MotionMarquee (Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Text/TitleFadeGeometry.swift,
// Motion/MotionMarquee.swift), the marquee of the tabs and the workspace sidebar. Same rules,
// same token values (MotionTunables defaults, plans/cmux-next/motion.md "Marquee"): after the
// pointer rests 0.6 s the title scrolls at 40 pt/s (at least 0.4 s), ease-in-out, until its last
// glyph sits where the fade starts; it holds 1.2 s, then returns with the `move` spring's timed
// length, ease-out. Leaving stops it; a title caught mid-scroll springs back with `disappear`.
// Reduce Motion never starts one (the full title is then in the tooltip). Pure: tested without a DOM.
import { MOTION_SPRINGS, springPerceivedDuration } from "../files-panel-motion";

/** MotionMarquee's tunables, in ms and px per second (MotionTunables.swift defaults). */
export const MOTION_MARQUEE = {
  delayMs: 600,
  pointsPerSecond: 40,
  minimumScrollMs: 400,
  holdMs: 1200,
  minimumTravel: 2,
} as const;

/** Where a title fades and how far its marquee scrolls (all lengths in the title's own px; 0 is its first glyph). */
export type TitleFadeInput = {
  /** Width of the whole title. */
  textWidth: number;
  /** Width the title may draw in at rest. */
  span: number;
  /** Where the title must be clear at rest (at most `span`). */
  visibleWidth: number;
  /** Padding after `visibleWidth` the fade may reach into. */
  trailingPadding: number;
  /** Longest trailing fade. */
  fadeWidth: number;
};

export type TitleFade = { truncated: boolean; fadeStart: number; fadeEnd: number; marqueeTravel: number };

export function titleFade(input: TitleFadeInput): TitleFade {
  const span = Math.max(0, input.span);
  const visibleWidth = Math.max(0, Math.min(input.visibleWidth, span));
  const textWidth = Math.max(0, input.textWidth);
  const truncated = span > 0 && textWidth > visibleWidth + 0.5;
  const fadeEnd = Math.min(span, visibleWidth + Math.max(0, input.trailingPadding));
  const length = Math.min(Math.max(0, input.fadeWidth), Math.max(fadeEnd, 1) * 0.5);
  const fadeStart = Math.max(0, fadeEnd - length);
  const marqueeTravel = truncated ? Math.ceil(Math.max(0, textWidth - fadeStart)) : 0;
  return { truncated, fadeStart, fadeEnd, marqueeTravel };
}

export type MarqueeTiming = { delayMs: number; scrollMs: number; holdMs: number; backMs: number };

/** The marquee for `travel` px, or null: nothing to reveal, or Reduce Motion. */
export function marqueeTiming(travel: number, reducedMotion: boolean): MarqueeTiming | null {
  if (reducedMotion || travel < MOTION_MARQUEE.minimumTravel) return null;
  return {
    delayMs: MOTION_MARQUEE.delayMs,
    scrollMs: Math.max(MOTION_MARQUEE.minimumScrollMs, (travel / MOTION_MARQUEE.pointsPerSecond) * 1000),
    holdMs: MOTION_MARQUEE.holdMs,
    backMs: Math.round(springPerceivedDuration(MOTION_SPRINGS.move) * 1000),
  };
}

/** One marquee pass on `translate` from 0 to -travel and back (the delay is the animation's). */
export function marqueeKeyframes(travel: number, timing: MarqueeTiming): { keyframes: Keyframe[]; duration: number } {
  const duration = timing.scrollMs + timing.holdMs + timing.backMs;
  const end = `${-travel}px 0`;
  return {
    duration,
    keyframes: [
      { offset: 0, translate: "0px 0", easing: "ease-in-out" },
      { offset: timing.scrollMs / duration, translate: end, easing: "linear" },
      { offset: (timing.scrollMs + timing.holdMs) / duration, translate: end, easing: "ease-out" },
      { offset: 1, translate: "0px 0" },
    ],
  };
}
