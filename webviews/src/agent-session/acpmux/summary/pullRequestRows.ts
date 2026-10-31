import type { AcpmuxRow, AcpmuxSnapshot } from "../model";

const NO_ROWS: readonly AcpmuxRow[] = [];

/// Keep PR parsing separate from the transcript's visual filtering and group expansion.
export function pullRequestRows(
  snapshot: Pick<AcpmuxSnapshot, "rows" | "subagentViews">,
  childRows?: readonly AcpmuxRow[],
  childId?: string,
): readonly AcpmuxRow[] {
  // childView filters and expands visual rows, losing the producer's command revision.
  // The raw child view already carries that revision, so each text token remains O(1).
  if (childRows) return (childId && snapshot.subagentViews?.[childId]) || NO_ROWS;
  return snapshot.rows;
}
