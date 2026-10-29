import type { AcpmuxRow, AcpmuxSnapshot } from "../model";

/// Keep PR parsing separate from the transcript's visual filtering and group expansion.
export function pullRequestRows(
  snapshot: Pick<AcpmuxSnapshot, "rows" | "subagentViews">,
  childRows?: readonly AcpmuxRow[],
  _childId?: string,
): readonly AcpmuxRow[] {
  return childRows ?? snapshot.rows;
}
