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

/// The newest changes by the number of the snapshot they made (`CHAIN` of them, numbers only): a
/// record the pane drew late (pane/paneSnapshot.ts `replayOwed`) is told from the snapshot the pane
/// drew, a few snapshots back, and a run of changes to one row is still one change from there.
const bySerial = new Map<number, { readonly from: number; readonly index: number }>();
const CHAIN = 64;

/// `rows` differ from `from`, the rows published before them, only at `index`.
export function markOneRowChange(rows: readonly AcpmuxRow[], from: readonly AcpmuxRow[], index: number): void {
  const change = { from: serialOf(from), index };
  oneRowChanges.set(rows, change);
  bySerial.set(serialOf(rows), change);
  if (bySerial.size > CHAIN) bySerial.delete(bySerial.keys().next().value!);
}

/// The one row `next` changed in place from `previous`, when the client said so: directly, or
/// through snapshots between them that each changed that same row.
export function oneRowChangeFrom(next: readonly AcpmuxRow[], previous: readonly AcpmuxRow[]): number | undefined {
  const change = oneRowChanges.get(next);
  const want = serials.get(previous);
  if (!change || want === undefined) return undefined;
  let step: { readonly from: number; readonly index: number } | undefined = change;
  for (let hops = 0; step && step.index === change.index && hops < CHAIN; hops += 1) {
    if (step.from === want) return change.index;
    step = bySerial.get(step.from);
  }
  return undefined;
}

/// What the client recorded of `rows`' change (tests: it holds no earlier snapshot).
export function oneRowChange(
  rows: readonly AcpmuxRow[],
): { readonly from: number; readonly index: number } | undefined {
  return oneRowChanges.get(rows);
}
