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
 * What a row's height depends on besides the width it is laid out at: its content's version (turns.ts
 * bumps it whenever the row's text, items or state change), whether its fold is open, and whether it
 * draws its reply actions. Two renders with the same hash at the same width are the same height.
 */
export function rowContentHash(version: number, open: boolean, actions: boolean): number {
  return ((version * 4 + (open ? 2 : 0) + (actions ? 1 : 0)) % 2_147_483_647) | 0;
}

type CachedHeight = { readonly hash: number; readonly width: number; readonly height: number };

/// The measurements a row keeps, newest first: enough to reopen a fold or go back to a width without
/// measuring again, never a row's whole history.
const KEPT_PER_ROW = 4;

/**
 * Measured heights keyed by row id, content hash and width (the design's height cache). An exact hit
 * is a height to trust. A miss falls back to the row's own latest height at that width, then at any
 * width, so a streamed token or a resize starts from the row's last size rather than the estimate;
 * the commit after it mounts measures the real one.
 */
export class HeightCache {
  private rows = new Map<string, CachedHeight[]>();

  /// `chat`: the chat whose rows these heights are; another chat's share none.
  constructor(readonly chat?: string) {}

  set(id: string, hash: number, width: number, height: number): void {
    const kept = this.rows.get(id);
    const entry = { hash, width, height };
    if (!kept) {
      this.rows.set(id, [entry]);
      return;
    }
    const at = kept.findIndex((each) => each.hash === hash && each.width === width);
    if (at >= 0) kept.splice(at, 1);
    kept.unshift(entry);
    if (kept.length > KEPT_PER_ROW) kept.length = KEPT_PER_ROW;
  }

  /** The height measured for exactly this content at this width, if there is one. */
  exact(id: string, hash: number, width: number): number | undefined {
    return this.rows.get(id)?.find((each) => each.hash === hash && each.width === width)?.height;
  }

  /** The best height known for the row: exact, else its latest at this width, else its latest. */
  get(id: string, hash: number, width: number): number | undefined {
    const kept = this.rows.get(id);
    if (!kept) return undefined;
    let sameWidth: number | undefined;
    for (const each of kept) {
      if (each.width !== width) continue;
      if (each.hash === hash) return each.height;
      sameWidth ??= each.height;
    }
    return sameWidth ?? kept[0]!.height;
  }

  get size(): number {
    return this.rows.size;
  }
}

/**
 * Heights for `rows` at `width`: measured ones from the cache (a row keeps its height across pages
 * and appends), the estimate for the rest.
 */
export function heightsFor(
  rows: readonly { readonly id: string; readonly hash: number }[],
  cache: HeightCache,
  width: number,
  estimate: number,
): number[] {
  return rows.map(({ id, hash }) => cache.get(id, hash, width) ?? estimate);
}
