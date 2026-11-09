// A flat map over transcript rows that reads again only the rows after the last one that is the same
// object as before. Rows change at their tail (a streamed token, a running call's output: the
// client keeps every unchanged row's object, direct.ts `OrderedRows`), so a snapshot's derived
// lists cost the rows it changed, not the whole chat (bench/transcript-replay.bench.ts long log:
// the pane's per-snapshot passes over every row made each update grow with the transcript).
// The identity walk over the kept rows is a pointer compare each.

/// One pass's result: the rows it read, the items, and where each row's items end.
export type PrefixFlat<R, T> = {
  readonly rows: readonly R[];
  readonly items: readonly T[];
  readonly ends: readonly number[];
};

/// `rows.flatMap(each)`, with `previous` (the last pass of the same `each`) reused for the rows it
/// read that are still the same objects at the same places. The same rows give `previous` back.
export function prefixFlatMap<R, T>(
  rows: readonly R[],
  each: (row: R) => readonly T[],
  previous?: PrefixFlat<R, T>,
): PrefixFlat<R, T> {
  let start = 0;
  if (previous) {
    const limit = Math.min(rows.length, previous.rows.length);
    while (start < limit && rows[start] === previous.rows[start]) start += 1;
    if (start === rows.length && rows.length === previous.rows.length) return previous;
  }
  const kept = start > 0 ? previous!.ends[start - 1]! : 0;
  const items = start > 0 ? previous!.items.slice(0, kept) : [];
  const ends = start > 0 ? previous!.ends.slice(0, start) : [];
  for (let index = start; index < rows.length; index += 1) {
    for (const item of each(rows[index]!)) items.push(item);
    ends.push(items.length);
  }
  return { rows, items, ends };
}

/// The last few passes of one `each`, for a function several views call with their own rows (the
/// pane's and Session Info's): each call starts from the pass that kept the most of its rows.
export class PrefixFlatCache<R, T> {
  private readonly passes: PrefixFlat<R, T>[] = [];
  constructor(
    private readonly each: (row: R) => readonly T[],
    private readonly size = 4,
  ) {}

  read(rows: readonly R[]): PrefixFlat<R, T> {
    let best: PrefixFlat<R, T> | undefined;
    let bestKept = 0;
    for (const pass of this.passes) {
      if (pass.rows === rows) return pass;
      const limit = Math.min(rows.length, pass.rows.length);
      let kept = 0;
      while (kept < limit && rows[kept] === pass.rows[kept]) kept += 1;
      if (kept > bestKept) {
        best = pass;
        bestKept = kept;
      }
    }
    const next = prefixFlatMap(rows, this.each, best);
    if (next !== best) {
      // A pass at least as long as the one it started from takes its place (the same view's next
      // snapshot); a shorter one is another view's, and both stay.
      if (best && rows.length >= best.rows.length) this.passes.splice(this.passes.indexOf(best), 1);
      this.passes.unshift(next);
      if (this.passes.length > this.size) this.passes.pop();
    }
    return next;
  }
}
