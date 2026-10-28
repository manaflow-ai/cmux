import type { AcpmuxRow } from "./model";

/**
 * Provenance for one immutable row snapshot. `previous` is weak so a live stream never retains
 * every historical snapshot; consumers use the hint only when that exact predecessor is still live.
 */
export type RowDeltaKind = "range" | "rebuild";
export type RowDelta = {
  previous?: readonly AcpmuxRow[];
  revision: number;
  from: number;
  to: number;
  kind: RowDeltaKind;
};

type StoredDelta = Omit<RowDelta, "previous"> & {
  previous?: WeakRef<readonly AcpmuxRow[]>;
};
const deltas = new WeakMap<readonly AcpmuxRow[], StoredDelta>();

export function markRowDelta(
  rows: readonly AcpmuxRow[],
  previous: readonly AcpmuxRow[] | undefined,
  delta: Omit<RowDelta, "previous">,
): void {
  deltas.set(rows, {
    ...delta,
    ...(previous ? { previous: new WeakRef(previous) } : {}),
  });
}

export function rowDelta(rows: readonly AcpmuxRow[]): RowDelta | undefined {
  const stored = deltas.get(rows);
  if (!stored) return undefined;
  const previous = stored.previous?.deref();
  return {
    revision: stored.revision,
    from: stored.from,
    to: stored.to,
    kind: stored.kind,
    ...(previous ? { previous } : {}),
  };
}
