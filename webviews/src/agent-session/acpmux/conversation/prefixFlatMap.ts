// A flat map over transcript rows that reads again only the rows after the last one that is the same
// object as before. Rows change at their tail (a streamed token, a running call's output: the
// client keeps every unchanged row's object, direct.ts `OrderedRows`), so a snapshot's derived
// lists cost the rows it changed, not the whole chat (bench/transcript-replay.bench.ts long log:
// the pane's per-snapshot passes over every row made each update grow with the transcript).
// The identity walk over the kept rows is a pointer compare each, and a pass keeps no per-row
// array: a chat of 35,000 rows copies only its items, never 35,000 row ends.

/// One pass's result: the rows it read, the items, and the index of the row each item came from
/// (non-decreasing).
export type PrefixFlat<R, T> = {
  readonly rows: readonly R[];
  readonly items: readonly T[];
  readonly from: readonly number[];
};

/// What the maker of an array said of its kept prefix (`noteKeptPrefix`): the array it was made
/// from, by number (holding the array would keep every earlier snapshot alive through the next, as
/// rowChanges.ts says), and how many leading rows it kept.
const told = new WeakMap<readonly unknown[], { from: number; count: number }>();
const serials = new WeakMap<readonly unknown[], number>();
let serial = 0;

/// `rows` begin with the first `count` rows of `previous`, the same objects at the same places: the
/// client says so of each snapshot (direct.ts `OrderedRows.sorted`, which knows the first slot an
/// event wrote), so `keptPrefix` answers without walking the chat. A tool call arriving in a chat
/// of 35,000 rows walked them once per pass that asked (bench/transcript-replay.bench.ts, god log).
/// `count` may be less than the true prefix, never more.
export function noteKeptPrefix(rows: readonly unknown[], previous: readonly unknown[], count: number): void {
  if (rows === previous) return;
  let from = serials.get(previous);
  if (from === undefined) serials.set(previous, (from = serial += 1));
  told.set(rows, { from, count: Math.max(0, Math.min(count, rows.length, previous.length)) });
}

/// The rows `keptPrefix` has walked since the page loaded: a test reads it to see that an update's
/// passes start at the change, not at the chat's first row (test/tool-call-kept-prefix.test.ts).
export const prefixWalks = { rows: 0 };

/// How many leading rows of `rows` are the same objects at the same places in `previous`. The pane
/// asks this of the same two snapshots once per pass (composer, tray, plan, Find, ...), so answers
/// are kept: each pair is walked once. They are kept by the arrays themselves (weakly), so a chat
/// that closed leaves none of its rows here.
/// (Snapshots are never written after they are made; the lengths are checked all the same.)
const kept = new WeakMap<readonly unknown[], WeakMap<readonly unknown[], { lengths: number; count: number }>>();
export function keptPrefix(previous: readonly unknown[], rows: readonly unknown[]): number {
  if (previous === rows) return rows.length;
  const said = told.get(rows);
  if (said && serials.get(previous) === said.from) return said.count;
  const lengths = previous.length * 2 ** 26 + rows.length;
  let after = kept.get(rows);
  const known = after?.get(previous);
  if (known?.lengths === lengths) return known.count;
  const limit = Math.min(rows.length, previous.length);
  let count = 0;
  while (count < limit && rows[count] === previous[count]) count += 1;
  prefixWalks.rows += count;
  if (!after) kept.set(rows, (after = new WeakMap()));
  after.set(previous, { lengths, count });
  return count;
}

/// `rows.flatMap(each)`, with `previous` (the last pass of the same `each`) reused for the rows it
/// read that are still the same objects at the same places. The same rows give `previous` back.
/// `each` may read the rows before its own (`rows[index - 1]`), never after: a kept row's items
/// stay its items only while what it read is kept too.
export function prefixFlatMap<R, T>(
  rows: readonly R[],
  each: (row: R, index: number, rows: readonly R[]) => readonly T[],
  previous?: PrefixFlat<R, T>,
): PrefixFlat<R, T> {
  const start = previous ? keptPrefix(previous.rows, rows) : 0;
  if (previous && start === rows.length && rows.length === previous.rows.length) return previous;
  let keep = 0;
  if (start > 0) {
    // The items of the kept rows: those before the first item of a row at or past `start`. Rows
    // change at the tail, so this walks back over the few items of the rows that changed.
    keep = previous!.from.length;
    while (keep > 0 && previous!.from[keep - 1]! >= start) keep -= 1;
  }
  const items = keep > 0 ? previous!.items.slice(0, keep) : [];
  const from = keep > 0 ? previous!.from.slice(0, keep) : [];
  for (let index = start; index < rows.length; index += 1)
    for (const item of each(rows[index]!, index, rows)) {
      items.push(item);
      from.push(index);
    }
  // A pass over these items (the next shaping step) starts after the kept ones too.
  if (previous) noteKeptPrefix(items, previous.items, keep);
  return { rows, items, from };
}

/// About how many steps of a walk (one identity compare each) one row's read costs.
const WALK_PER_READ = 64;

/// The last few passes of one `each`, for a function several views call with their own rows (the
/// pane's and Session Info's): each call starts from the pass that kept the most of its rows.
export class PrefixFlatCache<R, T> {
  /// The rows of the last few passes, newest first, held weakly: a pass lives only as long as the
  /// rows it read (`passes`), so a chat that closed leaves no rows or items here.
  private refs: WeakRef<readonly R[]>[] = [];
  private readonly passes = new WeakMap<readonly R[], PrefixFlat<R, T>>();
  constructor(
    private readonly each: (row: R, index: number, rows: readonly R[]) => readonly T[],
    private readonly size = 4,
  ) {}

  read(rows: readonly R[]): PrefixFlat<R, T> {
    const known = this.passes.get(rows);
    if (known) return known;
    let best: { ref: WeakRef<readonly R[]>; pass: PrefixFlat<R, T> } | undefined;
    let bestKept = 0;
    const live: WeakRef<readonly R[]>[] = [];
    // The rows its maker made them from (`noteKeptPrefix`), when a pass here read them: this view's
    // last snapshot. It starts from that pass with no walk against the other views' passes, each of
    // which was a walk over the chat.
    const said = told.get(rows);
    const held: { ref: WeakRef<readonly R[]>; pass: PrefixFlat<R, T>; bound: number }[] = [];
    for (const ref of this.refs) {
      const read = ref.deref();
      const pass = read && this.passes.get(read);
      if (!pass) continue;
      live.push(ref);
      held.push({ ref, pass, bound: Math.min(rows.length, pass.rows.length) });
      if (said && serials.get(read) === said.from) best = { ref, pass };
    }
    // No pass can keep more than both arrays hold, so the longest go first: this view's last pass,
    // which kept all but the rows the update changed. Once the best leaves few rows to gain against
    // a walk (a row's read costs about WALK_PER_READ steps of one), reading them again costs less
    // than walking the chat against another view's pass.
    if (!best)
      for (const { ref, pass, bound } of held.sort((a, b) => b.bound - a.bound)) {
        if (best && (bound - bestKept) * WALK_PER_READ <= bound) break;
        const count = keptPrefix(pass.rows, rows);
        if (count > bestKept) {
          best = { ref, pass };
          bestKept = count;
        }
      }
    const next = prefixFlatMap(rows, this.each, best?.pass);
    this.passes.set(rows, next);
    // A pass at least as long as the one it started from takes its place (the same view's next
    // snapshot); a shorter one is another view's, and both stay.
    const replaced = best && rows.length >= best.pass.rows.length ? best.ref : undefined;
    this.refs = [new WeakRef(rows), ...live.filter((ref) => ref !== replaced)].slice(0, this.size);
    return next;
  }
}

/// The rows `keep` says yes to, in order, read again only past the kept prefix (PrefixFlatCache).
export class PrefixFilter<R> {
  private readonly cache: PrefixFlatCache<R, R>;
  constructor(keep: (row: R, index: number, rows: readonly R[]) => boolean, size = 4) {
    this.cache = new PrefixFlatCache((row, index, rows) => (keep(row, index, rows) ? [row] : NONE), size);
  }

  /// The pass: `items` the rows kept, `from` their indexes in `rows`.
  read(rows: readonly R[]): PrefixFlat<R, R> {
    return this.cache.read(rows);
  }
}
const NONE: readonly never[] = [];
