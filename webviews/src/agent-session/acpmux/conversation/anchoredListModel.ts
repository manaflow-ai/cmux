// The anchored list's geometry (cmuxterm-hq docs/design/agent-transcript-clean-slate.md, step 4): row
// heights in a prefix-sum (Fenwick) tree, so a row's top and the row at an offset are O(log n) at any
// chat length, and the reader's place as an anchor, a row id and an offset, never a pixel.
//
// The invariants this keeps: the anchor is `(rowId, offsetPx)`; every commit reads it, changes the DOM,
// measures and writes it back in the same frame; a height change above the view goes into the offset in
// the frame it is measured; following the latest is a mode (`pinned`) that only the reader's scroll
// changes, and while pinned the anchor is the last row's bottom edge.

/** Row heights by index, with O(log n) prefix sums. */
export class HeightIndex {
  private tree: Float64Array;
  private heights: Float64Array;
  private count: number;

  constructor(heights: readonly number[] = []) {
    this.count = heights.length;
    this.heights = Float64Array.from(heights);
    this.tree = new Float64Array(this.count + 1);
    // O(n) build: each node adds itself to its parent once.
    for (let i = 1; i <= this.count; i++) {
      this.tree[i]! += this.heights[i - 1]!;
      const parent = i + (i & -i);
      if (parent <= this.count) this.tree[parent]! += this.tree[i]!;
    }
  }

  get size(): number {
    return this.count;
  }

  height(index: number): number {
    return this.heights[index] ?? 0;
  }

  /** Sets row `index`'s height; returns how much it changed. */
  set(index: number, height: number): number {
    const delta = height - this.heights[index]!;
    if (delta === 0) return 0;
    this.heights[index] = height;
    for (let i = index + 1; i <= this.count; i += i & -i) this.tree[i]! += delta;
    return delta;
  }

  /** The top of row `index` (the heights of the rows before it). */
  top(index: number): number {
    let sum = 0;
    for (let i = Math.min(index, this.count); i > 0; i -= i & -i) sum += this.tree[i]!;
    return sum;
  }

  total(): number {
    return this.top(this.count);
  }

  /** The row that `y` falls in (clamped to the rows there are). */
  indexAt(y: number): number {
    if (this.count === 0) return 0;
    let index = 0;
    let rest = y;
    for (let step = 1 << Math.floor(Math.log2(this.count)); step > 0; step >>= 1) {
      const next = index + step;
      if (next <= this.count && this.tree[next]! <= rest) {
        index = next;
        rest -= this.tree[next]!;
      }
    }
    return Math.min(index, this.count - 1);
  }
}

/** Where the reader is: a row and how far the viewport's top is below that row's top. */
export type Anchor = { readonly id: string; readonly offset: number };

/** The anchor for a viewport whose top is at `scrollTop`. */
export function anchorAt(index: HeightIndex, ids: readonly string[], scrollTop: number): Anchor | undefined {
  if (!ids.length) return undefined;
  const at = index.indexAt(Math.max(0, scrollTop));
  return { id: ids[at]!, offset: scrollTop - index.top(at) };
}

/**
 * The offset that puts the reader back: pinned, the end; otherwise the anchor row's top plus its
 * offset; a row that is gone, the nearest offset the scroller can take.
 */
export function offsetFor(
  index: HeightIndex,
  position: ReadonlyMap<string, number>,
  anchor: Anchor | undefined,
  pinned: boolean,
  viewport: number,
): number {
  const end = Math.max(0, index.total() - viewport);
  if (pinned || !anchor) return end;
  const at = position.get(anchor.id);
  if (at === undefined) return end;
  return Math.max(0, Math.min(end, index.top(at) + anchor.offset));
}

/** The rows to mount: the viewport and about a screen on each side. */
export function windowAt(index: HeightIndex, scrollTop: number, viewport: number): { first: number; last: number } {
  if (index.size === 0) return { first: 0, last: 0 };
  const first = index.indexAt(Math.max(0, scrollTop - viewport));
  const last = Math.min(index.size, index.indexAt(scrollTop + viewport * 2) + 1);
  return { first, last };
}

/**
 * Heights for `ids`: measured ones by id (a row keeps its height across pages and appends), the
 * estimate for the rest.
 */
export function heightsFor(ids: readonly string[], measured: ReadonlyMap<string, number>, estimate: number): number[] {
  return ids.map((id) => measured.get(id) ?? estimate);
}
