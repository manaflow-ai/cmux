// Late content settles in, it does not pop (cx-sya4n, Leo 2026-10-14: motion is small and local,
// as short as still feels comfortable; never whole panes travelling). The shared pieces, matched
// to the native kit (CmuxNextDesign Motion.reveal / Motion.stagger, plans/cmux-next/motion.md
// "Late content"); their CSS side is ui/motion.css.
//
// - reveal: a short fade with a few pixels of rise (`.ui-reveal`, or `reveal(element)`).
// - crossfade: new content fades in over the old in place (`.ui-crossfade`, the leaving child
//   marked `data-leaving`), so the layout never jumps.
// - stagger(i): the first few rows of a list arrive a step apart; later rows arrive with the last.
// Under Reduce Motion a reveal is a plain fade, nothing rises and nothing waits.

/** Delay between two staggered items, in ms. */
export const STAGGER_STEP_MS = 25;
/** Items that get their own step; later ones arrive with the last, so nothing lingers. */
export const STAGGER_ITEMS = 4;
/** How far revealed content rises as it settles, in px. */
export const REVEAL_RISE_PX = 3;
/** The reveal's length in ms: the native `appear` spring's settle time (MotionTunables, fast). */
export const REVEAL_MS = 167;
/** The native `appear` spring (response 0.18, damping 0.9) sampled to its 95% time, as CSS `linear()`. */
export const EASE_APPEAR =
  "linear(0, 0.088, 0.221, 0.394, 0.55, 0.679, 0.763, 0.84, 0.895, 0.927, 0.955, 0.973, 0.984, 0.99, 1)";

type MotionOptions = { reduced?: boolean };

/** Whether the person asked for less motion (false where there is no window). */
export function prefersReducedMotion(): boolean {
  return typeof window !== "undefined" && typeof window.matchMedia === "function"
    ? window.matchMedia("(prefers-reduced-motion: reduce)").matches
    : false;
}

/** The delay of item `index` in a staggered list, in ms; 0 under Reduce Motion. */
export function stagger(index: number, { reduced = prefersReducedMotion() }: MotionOptions = {}): number {
  if (reduced || !(index > 0)) return 0;
  return Math.min(Math.floor(index), STAGGER_ITEMS - 1) * STAGGER_STEP_MS;
}

/** A reveal's keyframes: fade and rise, or only the fade under Reduce Motion. */
export function revealKeyframes({ reduced = prefersReducedMotion() }: MotionOptions = {}): Keyframe[] {
  return reduced
    ? [{ opacity: 0 }, { opacity: 1 }]
    : [
        { opacity: 0, transform: `translateY(${REVEAL_RISE_PX}px)` },
        { opacity: 1, transform: "translateY(0)" },
      ];
}

/** Reveals `element` now (item `index` of a list); returns the animation, or null without one. */
export function reveal(element: Element, index = 0, options: MotionOptions = {}): Animation | null {
  if (typeof element.animate !== "function") return null;
  const reduced = options.reduced ?? prefersReducedMotion();
  return element.animate(revealKeyframes({ reduced }), {
    duration: reduced ? Math.min(REVEAL_MS, 100) : REVEAL_MS,
    delay: stagger(index, { reduced }),
    easing: reduced ? "ease-out" : EASE_APPEAR,
    fill: "backwards",
  });
}
