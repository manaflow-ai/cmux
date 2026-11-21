// Which row a client snapshot changed, when the client knows it is one row in place (direct.ts
// `OrderedRows.sorted`): the pane then reads that row alone instead of comparing every row
// (liveToolOutput.ts `toolOutputOnly`), so its check is O(1) in the transcript's length.
//
// A change names the snapshot it is from by number, never by the array: holding the array kept
// every earlier snapshot alive through the one after it (a running command's 1,000 updates over
// 5,000 rows kept 1,001 arrays). Each entry now dies with its own snapshot.
import type { AcpmuxRow } from "./model";

/// A snapshot's number, given when a change first names it.
const serials = new WeakMap<readonly AcpmuxRow[], number>();
let serial = 0;
const oneRowChanges = new WeakMap<readonly AcpmuxRow[], { readonly from: number; readonly index: number }>();

function serialOf(rows: readonly AcpmuxRow[]): number {
  let found = serials.get(rows);
  if (found === undefined) serials.set(rows, (found = serial += 1));
  return found;
}

/// `rows` differ from `from`, the rows published before them, only at `index`.
export function markOneRowChange(rows: readonly AcpmuxRow[], from: readonly AcpmuxRow[], index: number): void {
  oneRowChanges.set(rows, { from: serialOf(from), index });
}

/// The one row `next` changed in place from `previous`, when the client said so.
export function oneRowChangeFrom(next: readonly AcpmuxRow[], previous: readonly AcpmuxRow[]): number | undefined {
  const change = oneRowChanges.get(next);
  return change && serials.get(previous) === change.from ? change.index : undefined;
}

/// What the client recorded of `rows`' change (tests: it holds no earlier snapshot).
export function oneRowChange(
  rows: readonly AcpmuxRow[],
): { readonly from: number; readonly index: number } | undefined {
  return oneRowChanges.get(rows);
}
