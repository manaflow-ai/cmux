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
    if (height > 0) {
      const mark = marks?.[offset] ?? 0;
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

/// What the rows before leaf `leafIndex` sum to.
function prefixBeforeLeaf(
  root: Node | undefined,
  capacity: number,
  leafIndex: number,
  between: GapBetween | undefined,
): Summary {
  let prefix = EMPTY;
  let node = root;
  let low = 0;
  let high = capacity;
  while (node && high - low > 1) {
    const middle = low + ((high - low) >>> 1);
    if (leafIndex < middle) {
      node = node.left;
      high = middle;
    } else {
      prefix = join(prefix, summaryOf(node.left), between);
      node = node.right;
      low = middle;
    }
  }
  return prefix;
}

/// One row placed after the rows summarised by (top, drawn, lastMark): the walk `placeRows` takes.
type Cursor = { top: number; drawn: boolean; lastMark: number };

/**
 * Immutable gap-aware row placement. `update`, `splice` and `append` share
 * untouched tree nodes with their input; they never retain a reference to an
 * entire previous snapshot or mutate a shared leaf.
 */
export class PlacedHeightIndex {
  readonly count: number;
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
    return { last: summary.drawn > 0 ? summary.lastMark : 0, beforeLast: summary.beforeLastMark };
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
    if (height > 0) {
      cursor.top += this.gapOf(cursor, leaf, offset);
      cursor.drawn = true;
      cursor.lastMark = leaf.marks?.[offset] ?? 0;
    }
    const top = cursor.top;
    cursor.top += height;
    return top;
  }

  private cursorAtLeaf(leafIndex: number): Cursor {
    const prefix = prefixBeforeLeaf(this.root, this.capacity, leafIndex, this.rules.between);
    return { top: prefix.sum, drawn: prefix.drawn > 0, lastMark: prefix.lastMark };
  }

  /// The row's top: where the rows above it end, plus its own gap when it draws.
  topAt(index: number): number {
    if (!Number.isInteger(index) || index <= 0) return 0;
    if (index >= this.count) return this.totalHeight;
    const leafIndex = Math.floor(index / BLOCK_SIZE);
    const leaf = readLeaf(this.root, 0, this.capacity, leafIndex);
    const cursor = this.cursorAtLeaf(leafIndex);
    if (!leaf) return cursor.top;
    const offset = index % BLOCK_SIZE;
    for (let at = 0; at < offset; at += 1) this.step(cursor, leaf, at);
    return this.step(cursor, leaf, offset);
  }

  /// The gap the row takes above itself (0 for a row that draws nothing or the first drawn row).
  gapAt(index: number): number {
    if (!Number.isInteger(index) || index < 0 || index >= this.count) return 0;
    const leafIndex = Math.floor(index / BLOCK_SIZE);
    const leaf = readLeaf(this.root, 0, this.capacity, leafIndex);
    if (!leaf) return 0;
    const offset = index % BLOCK_SIZE;
    if (!(leaf.heights[offset]! > 0)) return 0;
    const cursor = this.cursorAtLeaf(leafIndex);
    for (let at = 0; at < offset; at += 1) this.step(cursor, leaf, at);
    return this.gapOf(cursor, leaf, offset);
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
    while (index < end) {
      const leaf = readLeaf(this.root, 0, this.capacity, leafIndex);
      if (!leaf) return;
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
    const leaf: Leaf = { heights, marks, gaps, summary: summarize(heights, marks, gaps, this.rules.between) };
    const between = this.rules.between;
    const replace = (node: Node | undefined, low: number, high: number): Node => {
      if (high - low === 1) return { leaf, summary: leaf.summary };
      const middle = low + ((high - low) >>> 1);
      const left = leafIndex < middle ? replace(node?.left, low, middle) : node?.left;
      const right = leafIndex >= middle ? replace(node?.right, middle, high) : node?.right;
      return { left, right, summary: join(summaryOf(left), summaryOf(right), between) };
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
    while (capacity < leafCount) {
      root = root ? { left: root, summary: root.summary } : undefined;
      capacity <<= 1;
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
      return { left, right, summary: join(summaryOf(left), summaryOf(right), between) };
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
    let prefix = EMPTY;
    let node = this.root;
    let low = 0;
    let high = this.capacity;
    // The descent picks the leftmost subtree whose last row's top is past `target`; a top
    // that rounding puts on the other side is caught by the leaf scans below.
    while (node && high - low > 1) {
      const middle = low + ((high - low) >>> 1);
      const left = summaryOf(node.left);
      const through = join(prefix, left, between);
      if (left.rows > 0 && through.sum - left.lastHeight > target) {
        node = node.left;
        high = middle;
      } else {
        prefix = through;
        node = node.right;
        low = middle;
      }
    }
    let leafIndex = Math.max(0, low - 1);
    // Scan from the leaf before the descent's, in case rounding put the answer there.
    const cursor = this.cursorAtLeaf(leafIndex);
    let index = leafIndex * BLOCK_SIZE;
    while (index < this.count) {
      const leaf = readLeaf(this.root, 0, this.capacity, leafIndex);
      if (!leaf) break;
      for (let offset = 0; offset < leaf.heights.length; offset += 1, index += 1)
        if (this.step(cursor, leaf, offset) > target) return index;
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
