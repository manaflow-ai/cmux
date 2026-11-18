// What a new rows array changed of the rows drawn before it, found once per pair of arrays and read
// by every pass of the transcript that used to find it itself (the placement, the estimate, the row
// arrivals, the drawn-row record, the presence hints, the frame budget, the references). Each walked
// the unchanged prefix on its own, and a page of older history, which changes the first row, made
// each of them read the whole chat again (bench/transcript-render-scale.bench.ts: a 100k-row chat's
// older page cost 215 ms, ten times a 10k chat's).
//
// A delta is a splice: the rows before `from` are the same objects at the same places, the rows from
// `end` on are the same objects as `base`'s from `baseEnd` on (rows that only moved, by
// `rows.length - base.length`), and `rows[from, end)` took the place of `base[from, baseEnd)`. A
// streamed token changes a row near the tail (`from` near the end); an older page lands before the
// first row (`from` 0, `end` the page's length, `baseEnd` 0).
//
// The prefix is the one keptPrefix (prefixFlatMap.ts) answers, which the maker of an array may tell it
// (`noteKeptPrefix`); the suffix is told the same way (`noteKeptSuffix`). A told count may be less than
// the true one, never more: the delta walks on from it to the first row that differs, so it is exact
// either way and costs the rows changed, plus whatever the maker did not tell.
import { keptPrefix } from "./prefixFlatMap";

export type RowsDelta = {
  readonly base: readonly unknown[];
  readonly rows: readonly unknown[];
  /// Rows before it are `base`'s, at the same places.
  readonly from: number;
  /// Rows from it on are `base`'s from `baseEnd` on.
  readonly end: number;
  readonly baseEnd: number;
};

/// What the maker of an array said of its kept suffix, as `noteKeptPrefix` keeps a prefix: the
/// array it was made from (weakly) and how many trailing rows it kept.
const toldSuffix = new WeakMap<readonly unknown[], { previous: WeakRef<readonly unknown[]>; count: number }>();

/// `rows` end with the last `count` rows of `previous`, the same objects in the same order: a page of
/// older history put before them, or rows taken from their head. `count` may be less than the true
/// suffix, never more.
export function noteKeptSuffix(rows: readonly unknown[], previous: readonly unknown[], count: number): void {
  if (rows === previous) return;
  toldSuffix.set(rows, {
    previous: new WeakRef(previous),
    count: Math.max(0, Math.min(count, rows.length, previous.length)),
  });
}

/// The delta found for each new array, against the base it was asked for (one base per array: the
/// rows drawn before it), the base by number: holding it would keep every earlier rows array alive
/// through the next, as prefixFlatMap.ts keeps its told prefixes.
const found = new WeakMap<readonly unknown[], { base: number; from: number; end: number; baseEnd: number }>();
const serials = new WeakMap<readonly unknown[], number>();
let serial = 0;
const serialOf = (rows: readonly unknown[]) => {
  let known = serials.get(rows);
  if (known === undefined) serials.set(rows, (known = serial += 1));
  return known;
};

/// The rows the delta walked since the page loaded beyond what the makers told: a test reads it to
/// see that an update's passes start at the change.
export const deltaWalks = { rows: 0 };

/// How `rows` differ from `base` (see the file comment). The same arrays give `from` = `end` = length.
export function rowsDelta(base: readonly unknown[], rows: readonly unknown[]): RowsDelta {
  const known = found.get(rows);
  if (known && known.base === serials.get(base))
    return { base, rows, from: known.from, end: known.end, baseEnd: known.baseEnd };
  const length = rows.length;
  const baseLength = base.length;
  if (base === rows) return { base, rows, from: length, end: length, baseEnd: baseLength };
  const limit = Math.min(length, baseLength);
  let from = Math.min(keptPrefix(base, rows), limit);
  const toldFrom = from;
  while (from < limit && rows[from] === base[from]) from += 1;
  // The suffix stops at the prefix: no row is counted in both.
  const room = limit - from;
  const said = toldSuffix.get(rows);
  let tail = said && said.previous.deref() === base ? Math.min(said.count, room) : 0;
  const toldTail = tail;
  while (tail < room && rows[length - 1 - tail] === base[baseLength - 1 - tail]) tail += 1;
  deltaWalks.rows += from - toldFrom + tail - toldTail;
  const delta = { base, rows, from, end: length - tail, baseEnd: baseLength - tail };
  found.set(rows, { base: serialOf(base), from, end: delta.end, baseEnd: delta.baseEnd });
  return delta;
}

/// The index in `delta.rows` of `base` row `index`, or -1 where that row was changed or taken out.
export function movedIndex(delta: RowsDelta, index: number): number {
  if (index < delta.from) return index;
  if (index >= delta.baseEnd && index < delta.base.length) return index + delta.end - delta.baseEnd;
  return -1;
}
