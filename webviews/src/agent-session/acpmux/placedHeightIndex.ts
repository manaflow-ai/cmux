/**
 * An immutable, gap-aware placement index for transcript rows.
 *
 * Each row has a height, a gap mark (transcriptGrid.ts `rowMark`) and, for a
 * layout placed without marks, a fixed gap of its own. A row's top is where
 * the rows above it end plus its own gap, and its gap depends on the nearest
 * row above it that draws (height > 0): rows that draw nothing take no gap and
 * are skipped when the next drawn row picks one. That is model.ts `placeRows`
 * exactly, folded into a tree:
 *
 * - rows sit in leaves of BLOCK_SIZE, each summarised as (rows, sum, drawn
 *   count, first and last two drawn marks, the first drawn row's own gap, the
 *   last row's height);
 * - two summaries join with the gap between the left's last drawn mark and the
 *   right's first, so a row that starts or stops drawing changes its
 *   neighbours' gaps without touching their leaves.
 *
 * A height correction copies one leaf and the logarithmic path to it; the
 * previous index is never mutated, which lets the anchor code compare two
 * layouts while a new one is prepared. Sums are joined in tree order, not
 * left to right, so a top can differ from the sequential pass by float
 * rounding only (far under a device pixel).
 */

const BLOCK_SIZE = 64;
/// The most leaves the tree spans (2^36 rows, more than a page holds). The descents halve `high - low` with `>>> 1`,
/// which is exact only below 2^32, and the doubling in `splice` was `capacity <<= 1`, which wraps to 0 past 2^31 and
/// then doubled 0 forever with the page's main thread held. A splice past it throws instead.
const MAX_LEAVES = 2 ** 30;

/// The mark of a row that carries its height but neither takes nor gives a gap: the rows on either
/// side gap as if it were not there. A row collapsing to nothing is placed so (model.ts
/// `collapsingHeight`), its own gaps folded into its height as it shrinks, so the rows under it move
/// with it and nothing steps when it reaches 0.
export const PASS_MARK = 255;

/// Whether a row takes and gives gaps: it draws (height > 0) and is no pass row.
const gapped = (height: number, mark: number) => height > 0 && mark !== PASS_MARK;

/// The gap between two drawn rows, by their marks (transcriptGrid.ts `transcriptGap` at a scale).
export type GapBetween = (previousMark: number, nextMark: number) => number;

/// How rows gap: by their marks (`between`), else by each row's own `gaps` entry, else not at all.
export type GapRules = { between?: GapBetween };

// Layout geometry is monotone and finite. Invalid measurements are treated as
// a zero-height row, preserving their position in the transcript.
function normalizeHeight(value: number): number {
  return Number.isFinite(value) && value >= 0 ? value : 0;
}

type Summary = {
  readonly rows: number;
  /// Where the segment's rows end, from its start, with the gaps between its own drawn rows.
  readonly sum: number;
  /// Drawn rows (height > 0), capped at 2: the tail metrics read the last two.
  readonly drawn: number;
  readonly firstMark: number;
  /// The first drawn row's own gap (layouts placed without marks).
  readonly firstGap: number;
  readonly lastMark: number;
  readonly beforeLastMark: number;
  /// The segment's last row's height: its top is `sum - lastHeight` (0 for a row that draws nothing).
  readonly lastHeight: number;
};

const EMPTY: Summary = {
  rows: 0,
  sum: 0,
  drawn: 0,
  firstMark: 0,
  firstGap: 0,
  lastMark: 0,
  beforeLastMark: 0,
  lastHeight: 0,
};

function join(a: Summary, b: Summary, between: GapBetween | undefined): Summary {
  if (b.rows === 0) return a;
  if (a.rows === 0) return b;
  const gap = a.drawn > 0 && b.drawn > 0 ? (between ? between(a.lastMark, b.firstMark) : b.firstGap) : 0;
  return {
    rows: a.rows + b.rows,
    sum: a.sum + gap + b.sum,
    drawn: Math.min(2, a.drawn + b.drawn),
    firstMark: a.drawn > 0 ? a.firstMark : b.firstMark,
    firstGap: a.drawn > 0 ? a.firstGap : b.firstGap,
    lastMark: b.drawn > 0 ? b.lastMark : a.lastMark,
    beforeLastMark: b.drawn > 1 ? b.beforeLastMark : b.drawn === 1 ? (a.drawn > 0 ? a.lastMark : 0) : a.beforeLastMark,
    lastHeight: b.lastHeight,
  };
}

type Leaf = {
  readonly heights: Float64Array;
  readonly marks?: Uint8Array;
  readonly gaps?: Float64Array;
  readonly summary: Summary;
};

type Node = {
  readonly summary: Summary;
  readonly left?: Node;
  readonly right?: Node;
  readonly leaf?: Leaf;
};

const summaryOf = (node: Node | undefined): Summary => node?.summary ?? EMPTY;

/// A leaf's summary, placed left to right as `placeRows` does.
function summarize(
  heights: Float64Array,
  marks: Uint8Array | undefined,
  gaps: Float64Array | undefined,
  between: GapBetween | undefined,
): Summary {
  let sum = 0;
  let drawn = 0;
  let firstMark = 0;
  let firstGap = 0;
  let lastMark = 0;
  let beforeLastMark = 0;
  for (let offset = 0; offset < heights.length; offset += 1) {
    const height = heights[offset]!;
    const mark = marks?.[offset] ?? 0;
    if (gapped(height, mark)) {
      if (drawn === 0) {
        firstMark = mark;
        firstGap = gaps?.[offset] ?? 0;
      } else sum += between ? between(lastMark, mark) : (gaps?.[offset] ?? 0);
      beforeLastMark = drawn > 0 ? lastMark : 0;
      lastMark = mark;
      drawn = Math.min(2, drawn + 1);
    }
    sum += height;
  }
  return {
    rows: heights.length,
    sum,
    drawn,
    firstMark,
    firstGap,
    lastMark,
    beforeLastMark,
    lastHeight: heights.length > 0 ? heights[heights.length - 1]! : 0,
  };
}

function readLeaf(node: Node | undefined, low: number, high: number, leafIndex: number): Leaf | undefined {
  // ends: each pass halves high - low
  while (node && high - low > 1) {
    const middle = low + ((high - low) >>> 1);
    if (leafIndex < middle) {
      node = node.left;
      high = middle;
    } else {
      node = node.right;
      low = middle;
    }
  }
  return node?.leaf;
}

/// The root-to-leaf prefix walks this module has made: a test reads it to see that the rows in view share one walk per
/// leaf, never one per row (placedHeightIndex.test.ts).
export const placedIndexStats = { prefixWalks: 0 };

/// What the rows before leaf `leafIndex` sum to, as the scalars a cursor starts from. The walk joins the left
/// sibling of every right turn the way `join` does (same gap, same order of sums), kept in locals: a Summary per
/// level made every row drawn in a frame allocate a chain of objects, which grew with the chat's depth.
function prefixBeforeLeaf(
  root: Node | undefined,
  capacity: number,
  leafIndex: number,
  between: GapBetween | undefined,
): Cursor {
  placedIndexStats.prefixWalks += 1;
  let sum = 0;
  let drawn = 0;
  let lastMark = 0;
  let node = root;
  let low = 0;
  let high = capacity;
  // ends: each pass halves high - low
  while (node && high - low > 1) {
    const middle = low + ((high - low) >>> 1);
    if (leafIndex < middle) {
      node = node.left;
      high = middle;
    } else {
      const left = summaryOf(node.left);
      if (left.rows > 0) {
        const gap = drawn > 0 && left.drawn > 0 ? (between ? between(lastMark, left.firstMark) : left.firstGap) : 0;
        sum = sum + gap + left.sum;
        if (left.drawn > 0) lastMark = left.lastMark;
        drawn = Math.min(2, drawn + left.drawn);
      }
      node = node.right;
      low = middle;
    }
  }
  return { top: sum, drawn: drawn > 0, lastMark };
}

/// A leaf's rows placed: each row's top and the gap over it (0 for a row that draws nothing).
type LeafPlaces = { readonly tops: Float64Array; readonly gaps: Float64Array };

/// One row placed after the rows summarised by (top, drawn, lastMark): the walk `placeRows` takes.
type Cursor = { top: number; drawn: boolean; lastMark: number };

/**
 * Immutable gap-aware row placement. `update`, `splice` and `append` share
 * untouched tree nodes with their input; they never retain a reference to an
 * entire previous snapshot or mutate a shared leaf.
 */
export class PlacedHeightIndex {
  readonly count: number;
  /// The starting cursor of each leaf asked for (`cursorAtLeaf`): a cache of what the immutable tree already says.
  private readonly leafCursors = new Map<number, Cursor>();
  /// The rows of each leaf asked for, placed (`placesOf`).
  private readonly leafPlaces = new Map<number, LeafPlaces>();
  /// Where the last row ends (gaps included).
  readonly totalHeight: number;

  private constructor(
    count: number,
    private readonly capacity: number,
    private readonly root: Node | undefined,
    private readonly rules: GapRules,
  ) {
    this.count = count;
    this.totalHeight = summaryOf(root).sum;
  }

  static empty(rules: GapRules = {}): PlacedHeightIndex {
    return new PlacedHeightIndex(0, 1, undefined, rules);
  }

  /// Plain prefix sums: no row takes a gap.
  static fromHeights(values: ArrayLike<number>): PlacedHeightIndex {
    return PlacedHeightIndex.fromRows(values);
  }

  /// Rows with their marks (gapped by `rules.between`) or their own gaps.
  static fromRows(
    heights: ArrayLike<number>,
    marks?: ArrayLike<number>,
    gaps?: ArrayLike<number>,
    rules: GapRules = {},
  ): PlacedHeightIndex {
    return PlacedHeightIndex.empty(rules).splice(0, heights, marks, gaps);
  }

  /// The gap rules this index places by.
  get gapRules(): GapRules {
    return this.rules;
  }

  /// Marks of the last two drawn rows (0 where there is none), for transcriptGrid.ts `tailGap`.
  get lastMarks(): { last: number; beforeLast: number } {
    const summary = summaryOf(this.root);
    return {
      last: summary.drawn > 0 ? summary.lastMark : 0,
      beforeLast: summary.beforeLastMark,
    };
  }

  private leafAt(index: number): Leaf | undefined {
    return readLeaf(this.root, 0, this.capacity, Math.floor(index / BLOCK_SIZE));
  }

  heightAt(index: number): number {
    if (!Number.isInteger(index) || index < 0 || index >= this.count) return 0;
    return this.leafAt(index)?.heights[index % BLOCK_SIZE] ?? 0;
  }

  markAt(index: number): number {
    if (!Number.isInteger(index) || index < 0 || index >= this.count) return 0;
    return this.leafAt(index)?.marks?.[index % BLOCK_SIZE] ?? 0;
  }

  private gapOf(cursor: Cursor, leaf: Leaf, offset: number): number {
    if (!cursor.drawn) return 0;
    const between = this.rules.between;
    return between ? between(cursor.lastMark, leaf.marks?.[offset] ?? 0) : (leaf.gaps?.[offset] ?? 0);
  }

  /// Steps `cursor` over row `offset` of `leaf`, returning that row's top.
  private step(cursor: Cursor, leaf: Leaf, offset: number): number {
    const height = leaf.heights[offset]!;
    if (gapped(height, leaf.marks?.[offset] ?? 0)) {
      cursor.top += this.gapOf(cursor, leaf, offset);
      cursor.drawn = true;
      cursor.lastMark = leaf.marks?.[offset] ?? 0;
    }
    const top = cursor.top;
    cursor.top += height;
    return top;
  }

  /// Where a walk over leaf `leafIndex` starts. The tree never changes, so each leaf's prefix is walked once for the
  /// snapshot (the rows in view ask for their tops and gaps one by one), and every caller steps its own copy.
  private cursorAtLeaf(leafIndex: number): Cursor {
    let known = this.leafCursors.get(leafIndex);
    if (!known) {
      known = prefixBeforeLeaf(this.root, this.capacity, leafIndex, this.rules.between);
      this.leafCursors.set(leafIndex, known);
    }
    return { top: known.top, drawn: known.drawn, lastMark: known.lastMark };
  }

  /// Every row of leaf `leafIndex` placed once: its tops and the gaps over its rows, stepped from the leaf's cursor as a
  /// walk over its rows does. A frame asks for the top and the gap of each mounted row, and a walk of the leaf up to
  /// each row (up to 63 steps, a boxed number each) made that cost the rows in view times a leaf, in a chat of any
  /// length; with the leaf placed once the rows in view cost one leaf each.
  private placesOf(leafIndex: number): LeafPlaces | undefined {
    const known = this.leafPlaces.get(leafIndex);
    if (known) return known;
    const leaf = readLeaf(this.root, 0, this.capacity, leafIndex);
    if (!leaf) return undefined;
    const cursor = this.cursorAtLeaf(leafIndex);
    const rows = leaf.heights.length;
    const places = { tops: new Float64Array(rows), gaps: new Float64Array(rows) };
    for (let at = 0; at < rows; at += 1) {
      if (gapped(leaf.heights[at]!, leaf.marks?.[at] ?? 0)) places.gaps[at] = this.gapOf(cursor, leaf, at);
      places.tops[at] = this.step(cursor, leaf, at);
    }
    this.leafPlaces.set(leafIndex, places);
    return places;
  }

  /// The row's top: where the rows above it end, plus its own gap when it draws.
  topAt(index: number): number {
    if (!Number.isInteger(index) || index <= 0) return 0;
    if (index >= this.count) return this.totalHeight;
    const leafIndex = Math.floor(index / BLOCK_SIZE);
    const places = this.placesOf(leafIndex);
    if (!places) return this.cursorAtLeaf(leafIndex).top;
    return places.tops[index % BLOCK_SIZE]!;
  }

  /// The gap the row takes above itself (0 for a row that draws nothing or the first drawn row).
  gapAt(index: number): number {
    if (!Number.isInteger(index) || index < 0 || index >= this.count) return 0;
    return this.placesOf(Math.floor(index / BLOCK_SIZE))?.gaps[index % BLOCK_SIZE] ?? 0;
  }

  /**
   * Visits rows `from` to `to` (exclusive) in order with their tops and heights, in
   * O(log rows + visited). Stops early when `visit` returns false.
   */
  scan(from: number, to: number, visit: (index: number, top: number, height: number) => boolean | void): void {
    const start = Math.max(0, Math.floor(from));
    const end = Math.min(this.count, Math.ceil(to));
    if (start >= end) return;
    let leafIndex = Math.floor(start / BLOCK_SIZE);
    const cursor = this.cursorAtLeaf(leafIndex);
    let index = leafIndex * BLOCK_SIZE;
    // ends: each pass reads the next leaf, which holds at least one row, so `index` rises; no leaf, or an empty one,
    // returns
    while (index < end) {
      const leaf = readLeaf(this.root, 0, this.capacity, leafIndex);
      if (!leaf || leaf.heights.length === 0) return;
      for (let offset = 0; offset < leaf.heights.length && index < end; offset += 1, index += 1) {
        const top = this.step(cursor, leaf, offset);
        if (index >= start && visit(index, top, leaf.heights[offset]!) === false) return;
      }
      leafIndex += 1;
    }
  }

  /** Returns a new index with one row's height (and mark or own gap, when given) replaced. */
  update(index: number, value: number, mark?: number, gap?: number): PlacedHeightIndex {
    if (!Number.isInteger(index) || index < 0 || index >= this.count || !Number.isFinite(value) || value < 0)
      return this;
    const offset = index % BLOCK_SIZE;
    const leafIndex = Math.floor(index / BLOCK_SIZE);
    const previous = readLeaf(this.root, 0, this.capacity, leafIndex);
    if (!previous) return this;
    const sameMark = mark === undefined || (previous.marks?.[offset] ?? 0) === mark;
    const sameGap = gap === undefined || (previous.gaps?.[offset] ?? 0) === gap;
    if (previous.heights[offset] === value && sameMark && sameGap) return this;
    const heights = Float64Array.from(previous.heights);
    heights[offset] = value;
    let marks = previous.marks;
    if (!sameMark) {
      marks = marks ? Uint8Array.from(marks) : new Uint8Array(heights.length);
      marks[offset] = mark!;
    }
    let gaps = previous.gaps;
    if (!sameGap) {
      gaps = gaps ? Float64Array.from(gaps) : new Float64Array(heights.length);
      gaps[offset] = gap!;
    }
    // Re-sum the copied bounded leaf instead of subtracting floating-point
    // values from the old aggregate: corrections that settle must settle exactly.
    const leaf: Leaf = {
      heights,
      marks,
      gaps,
      summary: summarize(heights, marks, gaps, this.rules.between),
    };
    const between = this.rules.between;
    const replace = (node: Node | undefined, low: number, high: number): Node => {
      if (high - low === 1) return { leaf, summary: leaf.summary };
      const middle = low + ((high - low) >>> 1);
      const left = leafIndex < middle ? replace(node?.left, low, middle) : node?.left;
      const right = leafIndex >= middle ? replace(node?.right, middle, high) : node?.right;
      return {
        left,
        right,
        summary: join(summaryOf(left), summaryOf(right), between),
      };
    };
    return new PlacedHeightIndex(this.count, this.capacity, replace(this.root, 0, this.capacity), this.rules);
  }

  /**
   * Returns a new index whose rows from `from` on are `heights` (with `marks` and `gaps`):
   * a truncate, an append, or a new tail. Rows before `from` keep their leaves; the cost is
   * O(log rows + BLOCK_SIZE + new rows).
   */
  splice(
    from: number,
    heights: ArrayLike<number>,
    marks?: ArrayLike<number>,
    gaps?: ArrayLike<number>,
  ): PlacedHeightIndex {
    const start = Math.max(0, Math.min(this.count, Math.floor(from)));
    const count = start + heights.length;
    const leafCount = Math.max(1, Math.ceil(count / BLOCK_SIZE));
    let capacity = this.capacity;
    let root = this.root;
    if (leafCount > MAX_LEAVES)
      throw new RangeError(`PlacedHeightIndex: ${count} rows is past the most it places (${MAX_LEAVES * BLOCK_SIZE})`);
    // ends: `capacity` doubles each pass, and `leafCount` is at most MAX_LEAVES, a power of two
    while (capacity < leafCount) {
      root = root ? { left: root, summary: root.summary } : undefined;
      capacity *= 2;
    }
    const between = this.rules.between;
    const fromLeaf = Math.floor(start / BLOCK_SIZE);
    const withMarks = marks !== undefined || between !== undefined;
    const build = (node: Node | undefined, low: number, high: number): Node | undefined => {
      if (high <= fromLeaf) return node;
      if (low * BLOCK_SIZE >= count) return undefined;
      if (high - low === 1) {
        const first = low * BLOCK_SIZE;
        const length = Math.min(BLOCK_SIZE, count - first);
        const old = node?.leaf;
        const leafHeights = new Float64Array(length);
        const leafMarks = withMarks ? new Uint8Array(length) : undefined;
        const leafGaps = gaps || old?.gaps ? new Float64Array(length) : undefined;
        for (let offset = 0; offset < length; offset += 1) {
          const row = first + offset;
          if (row < start) {
            leafHeights[offset] = old?.heights[offset] ?? 0;
            if (leafMarks) leafMarks[offset] = old?.marks?.[offset] ?? 0;
            if (leafGaps) leafGaps[offset] = old?.gaps?.[offset] ?? 0;
          } else {
            leafHeights[offset] = normalizeHeight(heights[row - start] ?? 0);
            if (leafMarks) leafMarks[offset] = marks?.[row - start] ?? 0;
            if (leafGaps) leafGaps[offset] = gaps?.[row - start] ?? 0;
          }
        }
        const leaf: Leaf = {
          heights: leafHeights,
          marks: leafMarks,
          gaps: leafGaps,
          summary: summarize(leafHeights, leafMarks, leafGaps, between),
        };
        return { leaf, summary: leaf.summary };
      }
      const middle = low + ((high - low) >>> 1);
      const left = build(node?.left, low, middle);
      const right = build(node?.right, middle, high);
      if (!left && !right) return undefined;
      return {
        left,
        right,
        summary: join(summaryOf(left), summaryOf(right), between),
      };
    };
    return new PlacedHeightIndex(count, capacity, build(root, 0, capacity), this.rules);
  }

  /** Returns a new index with the supplied rows appended. */
  append(values: ArrayLike<number>, marks?: ArrayLike<number>, gaps?: ArrayLike<number>): PlacedHeightIndex {
    if (values.length === 0) return this;
    return this.splice(this.count, values, marks, gaps);
  }

  /** Finds the first row whose top is greater than `target` (upper-bound semantics). */
  upperBoundTop(target: number): number {
    const between = this.rules.between;
    // The prefix joined so far, in scalars (`prefixBeforeLeaf`).
    let sum = 0;
    let drawn = 0;
    let lastMark = 0;
    let node = this.root;
    let low = 0;
    let high = this.capacity;
    // The descent picks the leftmost subtree whose last row's top is past `target`; a top
    // that rounding puts on the other side is caught by the leaf scans below.
    // ends: each pass halves high - low
    while (node && high - low > 1) {
      const middle = low + ((high - low) >>> 1);
      const left = summaryOf(node.left);
      let through = sum;
      if (left.rows > 0) {
        const gap = drawn > 0 && left.drawn > 0 ? (between ? between(lastMark, left.firstMark) : left.firstGap) : 0;
        through = sum + gap + left.sum;
      }
      if (left.rows > 0 && through - left.lastHeight > target) {
        node = node.left;
        high = middle;
      } else {
        if (left.rows > 0) {
          sum = through;
          if (left.drawn > 0) lastMark = left.lastMark;
          drawn = Math.min(2, drawn + left.drawn);
        }
        node = node.right;
        low = middle;
      }
    }
    let leafIndex = Math.max(0, low - 1);
    // Scan from the leaf before the descent's, in case rounding put the answer there.
    // ends: `leafIndex` rises by one each pass, past the last row's leaf at most
    while (leafIndex * BLOCK_SIZE < this.count) {
      const places = this.placesOf(leafIndex);
      if (!places) break;
      for (let offset = 0; offset < places.tops.length; offset += 1)
        if (places.tops[offset]! > target) return leafIndex * BLOCK_SIZE + offset;
      leafIndex += 1;
    }
    return this.count;
  }

  /** Explicitly materializes a compatibility array for consumers that need one. */
  materializeHeights(): Float64Array {
    const values = new Float64Array(this.count);
    this.scan(0, this.count, (index, _top, height) => {
      values[index] = height;
    });
    return values;
  }

  /** Explicitly materializes row tops for legacy consumers. */
  materializeTops(): Float64Array {
    const values = new Float64Array(this.count);
    this.scan(0, this.count, (index, top) => {
      values[index] = top;
    });
    return values;
  }
}

export const PLACED_HEIGHT_BLOCK_SIZE = BLOCK_SIZE;
