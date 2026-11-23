// The transcript's stand-ins (VirtualTranscript `standIns`; cmuxterm-hq docs/design/transcript-motion-model.md):
// a viewport either side of the view is never bare spacer. A row there that is not mounted in full is
// one empty element at its placed box: no children and no class, so no per-row rule (`.acpmux-row`,
// a `:has()` over a row's content, a descendant rule) styles or matches it. The rows a scroll mounts
// are still the ones it mounted before (the view, its lead and its trail); the warm rows (a deferred
// render once the scroll's lead decays) mount the rest in full, as before.

import type { RowRange } from "../model";

/// Viewports either side of the view that are covered: by full rows where they are mounted, by
/// stand-ins where they are not.
export const STAND_IN_VIEWPORTS = 1;

/// The rows of `overscan` that no range of `mounted` (sorted, not overlapping: mergeRowRanges) holds.
export function standInRanges(overscan: RowRange, mounted: readonly RowRange[]): RowRange[] {
  const out: RowRange[] = [];
  let from = overscan.first;
  for (const range of mounted) {
    if (range.last <= from) continue;
    if (range.first >= overscan.last) break;
    if (range.first > from) out.push({ first: from, last: range.first });
    from = Math.max(from, range.last);
    if (from >= overscan.last) break;
  }
  if (from < overscan.last) out.push({ first: from, last: overscan.last });
  return out;
}
