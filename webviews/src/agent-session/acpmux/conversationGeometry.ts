import { PlacedHeightIndex } from "./placedHeightIndex";

/**
 * Read-only transcript geometry.  The accessors are backed by an immutable
 * prefix index; callers do not need to materialize tops or heights to answer
 * a range or anchor query.
 */
export type LayoutGeometry = {
  readonly count: number;
  readonly totalHeight: number;
  readonly topAt: (index: number) => number;
  readonly heightAt: (index: number) => number;
  readonly upperBoundTop: (target: number) => number;
};

/** Legacy callers and fixtures may supply explicit arrays; production uses LayoutGeometry. */
export type LayoutSource =
  | LayoutGeometry
  | {
      tops: ArrayLike<number>;
      heights: ArrayLike<number>;
      totalHeight: number;
    };

/** Adapts explicit legacy arrays by reference, without copying or caching them. */
export function readGeometry(source: LayoutSource): LayoutGeometry {
  if ("topAt" in source) return source;
  return {
    count: source.heights.length,
    totalHeight: source.totalHeight,
    topAt: (index) => source.tops[index] ?? source.totalHeight,
    heightAt: (index) => source.heights[index] ?? 0,
    upperBoundTop: (target) => {
      let low = 0;
      let high = source.tops.length;
      while (low < high) {
        const middle = (low + high) >>> 1;
        if (source.tops[middle]! <= target) low = middle + 1;
        else high = middle;
      }
      return low;
    },
  };
}

/** Geometry together with its persistent source, for bounded point updates. */
export type IndexedLayoutGeometry = LayoutGeometry & {
  readonly index: PlacedHeightIndex;
};

export type HeightChange = {
  readonly index: number;
  readonly height: number;
};

export function geometryFromIndex(index: PlacedHeightIndex): IndexedLayoutGeometry {
  return {
    count: index.count,
    totalHeight: index.totalHeight,
    topAt: (at) => index.topAt(at),
    heightAt: (at) => index.heightAt(at),
    upperBoundTop: (target) => index.upperBoundTop(target),
    index,
  };
}

/** Builds the initial estimate once; later measurements should use applyHeightChanges. */
export function geometryFromHeights(heights: ArrayLike<number>): IndexedLayoutGeometry {
  return geometryFromIndex(PlacedHeightIndex.fromHeights(heights));
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
  return index === previous.index ? previous : geometryFromIndex(index);
}

/**
 * Reconciles changed estimates and drawn reports against the previous placement.
 * `from` is the first revised estimate. A compatible row order preserves all
 * previously measured points; structural resets restore measurements once.
 */
export function placeMeasuredRows(
  estimate: IndexedLayoutGeometry,
  heightAt: (index: number) => number | undefined,
  changed: Iterable<number>,
  previous?: { layout: IndexedLayoutGeometry; from: number },
): IndexedLayoutGeometry {
  let index = previous?.layout.index ?? estimate.index;
  const height = (at: number) => {
    const drawn = heightAt(at);
    return drawn !== undefined && Number.isFinite(drawn) && drawn >= 0 ? drawn : estimate.heightAt(at);
  };
  const from = previous?.from ?? 0;
  for (let at = from; at < estimate.count; at += 1) {
    const value = height(at);
    index = at < index.count ? index.update(at, value) : index.append([value]);
  }
  for (const at of changed) {
    if (!Number.isInteger(at) || at < 0 || at >= Math.min(from, estimate.count)) continue;
    index = index.update(at, height(at));
  }
  if (index === previous?.layout.index) return previous.layout;
  return index === estimate.index ? estimate : geometryFromIndex(index);
}
