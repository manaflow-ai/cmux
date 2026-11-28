// The numbers docs/cmux-next/ui-guidelines.md sets for chevrons (Leo, 2026-11-27: "these chevrons are too close dont
// we have any guidelines for these yet?"). test/chevron-spacing.test.ts measures every pager against
// them in Chromium; test/chevron-motion.test.ts holds the motion rule over the stylesheets.

/** A chevron's 12 px glyph box to the nearest text or glyph beside it, in px (--ds-space-2). */
export const CHEVRON_MIN_GAP = 8;
/** A chevron that is a button on its own (a pager step, a tuck): its box, in px (--ds-control-compact). */
export const CHEVRON_MIN_TARGET = 24;
/** A chevron's turn or slide: the longest it may take, in ms (--cmux-motion-standard). */
export const CHEVRON_MAX_MOTION_MS = 180; // motion-allow: the guideline ceiling, --cmux-motion-standard, named for the lint

export type PagerMeasure = {
  /** Each step button's width and height. */
  targets: { width: number; height: number }[];
  /** Previous chevron's glyph to the count, then the count to Next's glyph. */
  gaps: number[];
};

/** What a measured pager breaks of the guideline, as sentences; empty when it holds. */
export function chevronPagerFaults(measure: PagerMeasure): string[] {
  const faults: string[] = [];
  measure.gaps.forEach((gap, index) => {
    if (gap < CHEVRON_MIN_GAP - 0.5)
      faults.push(
        `${index === 0 ? "previous" : "next"} chevron stands ${gap} px from the count (< ${CHEVRON_MIN_GAP})`,
      );
  });
  measure.targets.forEach((target, index) => {
    if (Math.min(target.width, target.height) < CHEVRON_MIN_TARGET - 0.5)
      faults.push(`step ${index} is ${target.width}x${target.height} (< ${CHEVRON_MIN_TARGET})`);
  });
  return faults;
}
