// Which row a client snapshot changed, when the client knows it is one row in place (direct.ts
// `OrderedRows.sorted`): the pane then reads that row alone instead of comparing every row
// (liveToolOutput.ts `toolOutputOnly`), so its check is O(1) in the transcript's length.
import type { AcpmuxRow } from "./model";

const oneRowChanges = new WeakMap<readonly AcpmuxRow[], { from: readonly AcpmuxRow[]; index: number }>();

/// `rows` differ from `from`, the rows published before them, only at `index`.
export function markOneRowChange(rows: readonly AcpmuxRow[], from: readonly AcpmuxRow[], index: number): void {
  oneRowChanges.set(rows, { from, index });
}

/// The one row `rows` changed in place, and the rows it changed from, when the client said so.
export function oneRowChange(rows: readonly AcpmuxRow[]): { from: readonly AcpmuxRow[]; index: number } | undefined {
  return oneRowChanges.get(rows);
}
