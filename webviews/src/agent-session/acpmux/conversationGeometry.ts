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
