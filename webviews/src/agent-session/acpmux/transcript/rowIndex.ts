import { type AcpmuxRow } from "../model";

/// The index of row `id` in `rows`, starting from where it was last found (`hint`): the transcript
/// mostly appends, so the hint holds and the lookup is O(1); a miss scans once.
export function indexOfRow(rows: readonly AcpmuxRow[], id: string | undefined, hint: { current: number }): number {
  if (id === undefined) return -1;
  if (rows[hint.current]?.id === id) return hint.current;
  const at = rows.findIndex((row) => row.id === id);
  hint.current = at;
  return at;
}

/// The index of mounted row `id` in `rows`, or -1 (a row not mounted has no place on the page):
/// O(mounted rows) id compares at most, never the chat's length.
export function mountedIndexOf(
  rows: readonly AcpmuxRow[],
  mounted: readonly { first: number; last: number }[],
  id: string,
): number {
  for (const { first, last } of mounted)
    for (let index = first; index < last; index++) if (rows[index]?.id === id) return index;
  return -1;
}
