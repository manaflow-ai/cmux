// The diff tab's open timeline: when each step of the open happened (ms after the page's navigation
// start), and one report to the host once the first hunk is on screen (`cmux.diff.shown`). The
// instant-surfaces bench's `diff_right` command times "input to first visible hunk" from that report
// (scripts/cmux-next/instant-new-surfaces-bench.py) and prints the steps, so a slow open names its
// slow step. A host that does not serve the op ignores it; nothing waits on it.
import type { PageClient } from "../pages/shared/pageClient";

export const DIFF_SHOWN_OP = "cmux.diff.shown";

/** The steps of an open, in order. */
export type DiffOpenStep =
  | "boot"
  | "config"
  | "render"
  | "sessionOpen"
  | "sessionOpened"
  | "firstBatch"
  | "firstHunk"
  | "painted";

const marks = new Map<DiffOpenStep, number>();
let reported = false;
let adopted = false;

/** Records `step` once per page load (the first time is the one that counts). */
export function markDiffOpen(step: DiffOpenStep): void {
  if (!marks.has(step)) marks.set(step, Math.round(performance.now() * 10) / 10);
}

/** The session the page showed first was one the host had already opened (precomputed or pre-opened). */
export function markDiffAdopted(value: boolean): void {
  adopted = value;
}

/** The marks so far, by step. */
export function diffOpenMarks(): Partial<Record<DiffOpenStep, number>> {
  return Object.fromEntries(marks);
}

/**
 * A file with hunks drew its rows: marks `firstHunk`, then on the next frame `painted` and reports
 * the timeline to the host, once per page load.
 */
export function reportFirstHunk(page: PageClient | null, files: number): void {
  if (reported) return;
  reported = true;
  markDiffOpen("firstHunk");
  requestAnimationFrame(() => {
    markDiffOpen("painted");
    void page?.call(DIFF_SHOWN_OP, { marks: diffOpenMarks(), files, adopted }).catch(() => {});
  });
}

/** Test hook: forgets the marks and the report. */
export function resetDiffOpenTimingForTesting(): void {
  marks.clear();
  reported = false;
  adopted = false;
}
