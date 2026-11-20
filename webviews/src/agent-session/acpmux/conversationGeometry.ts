import { PlacedHeightIndex } from "./placedHeightIndex";

/**
 * Read-only transcript geometry. Placed layouts are backed by an immutable
 * gap-aware index (placedHeightIndex.ts), estimates by their arrays; callers
 * answer range, anchor and fold queries through these accessors without
 * materializing tops or heights.
 */
export type LayoutGeometry = {
  readonly count: number;
  /// Where the last row ends, origin included.
  readonly totalHeight: number;
  /// A row's top (origin included); `count` and past give `totalHeight`.
  readonly topAt: (index: number) => number;
  readonly heightAt: (index: number) => number;
  /// The gap the row takes above itself: its top less where the row before it ends.
  readonly gapAt: (index: number) => number;
  /// The first row whose top is greater than `target`, `count` when none is.
  readonly upperBoundTop: (target: number) => number;
  /// Visits rows `from` to `to` (exclusive) in order; `visit` returning false stops.
  readonly scan: (
    from: number,
    to: number,
    visit: (index: number, top: number, height: number) => boolean | void,
  ) => void;
};

/** Geometry together with its persistent source, for bounded point updates. */
export type IndexedLayoutGeometry = LayoutGeometry & {
  readonly index: PlacedHeightIndex;
  /// Room above the first row (ConversationLayout.origin), added to every top.
  readonly origin: number;
};

export type HeightChange = {
  readonly index: number;
  readonly height: number;
};

export function geometryFromIndex(index: PlacedHeightIndex, origin = 0): IndexedLayoutGeometry {
  return {
    count: index.count,
    totalHeight: origin + index.totalHeight,
    topAt: (at) => origin + index.topAt(at),
    heightAt: (at) => index.heightAt(at),
    gapAt: (at) => index.gapAt(at),
    upperBoundTop: (target) => index.upperBoundTop(target - origin),
    scan: (from, to, visit) => index.scan(from, to, (at, top, height) => visit(at, origin + top, height)),
    index,
    origin,
  };
}

/** Builds the initial estimate once; later measurements should use applyHeightChanges. */
export function geometryFromHeights(heights: ArrayLike<number>): IndexedLayoutGeometry {
  return geometryFromIndex(PlacedHeightIndex.fromHeights(heights));
}

function upperBound(values: ArrayLike<number>, target: number): number {
  let low = 0;
  let high = values.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (values[middle]! <= target) low = middle + 1;
    else high = middle;
  }
  return low;
}

/**
 * Geometry over a placed pair of arrays (an estimate, or a layout a test builds), shifted
 * by `by`. O(1) to make: nothing is copied.
 */
export function geometryFromArrays(
  tops: ArrayLike<number>,
  heights: ArrayLike<number>,
  totalHeight: number,
  by = 0,
): LayoutGeometry {
  const count = Math.min(tops.length, heights.length);
  return {
    count,
    totalHeight: totalHeight + by,
    topAt: (at) => (at >= count ? totalHeight + by : at < 0 ? by : (tops[at] ?? 0) + by),
    heightAt: (at) => heights[at] ?? 0,
    gapAt: (at) =>
      at > 0 && at < count && heights[at]! > 0 ? Math.max(0, tops[at]! - tops[at - 1]! - heights[at - 1]!) : 0,
    upperBoundTop: (target) => upperBound(tops, target - by),
    scan: (from, to, visit) => {
      for (let at = Math.max(0, from); at < Math.min(count, to); at += 1)
        if (visit(at, tops[at]! + by, heights[at]!) === false) return;
    },
  };
}

/// A layout either kind of placement gives: a placement's geometry, or an estimate's arrays.
export type GeometrySource =
  | { readonly geometry: LayoutGeometry }
  | { readonly tops: ArrayLike<number>; readonly heights: ArrayLike<number>; readonly totalHeight: number };

/// The geometry of either kind of layout: O(1), nothing is copied. (model.ts `layoutGeometry`;
/// here so geometry readers need not load the transcript model.)
export function geometryOf(layout: GeometrySource): LayoutGeometry {
  return "geometry" in layout ? layout.geometry : geometryFromArrays(layout.tops, layout.heights, layout.totalHeight);
}

/**
 * Applies only the supplied measured rows.  Each change copies one bounded
 * leaf and its tree path, while the input geometry remains an anchor-safe
 * immutable snapshot.  The caller owns the changed-index list and should keep
 * it limited to rows whose drawn height actually changed.
 */
export function applyHeightChanges(
  previous: IndexedLayoutGeometry,
  changes: readonly HeightChange[],
): IndexedLayoutGeometry {
  let index = previous.index;
  for (const change of changes) {
    if (!Number.isInteger(change.index) || change.index < 0 || change.index >= index.count) continue;
    if (!Number.isFinite(change.height) || change.height < 0) continue;
    index = index.update(change.index, change.height);
  }
  return index === previous.index ? previous : geometryFromIndex(index, previous.origin);
}
