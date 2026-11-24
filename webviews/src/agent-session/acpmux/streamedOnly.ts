import type { AcpmuxSnapshot } from "./model";
import { drawsAsIs, streamingRowBlocked, textOnlyRow } from "./streamingRow";

/// The index of the streaming reply's row when `next` differs from `drawn` only in that row's
/// text (HOT PATH AUDIT area F, row W1), else -1. Every other field compares by identity: the client
/// keeps the same objects while they do not change (direct.ts `publishedSummary`, `NO_CATALOG`,
/// subagentFold.ts `views`), so this is O(fields + rows), with no serialization. Drawn only while
/// the transcript draws that row as the client holds it (`drawsAsIs`) and no view that reads the
/// pane's rows is open (`streamingRowBlocked`).
export function streamedOnly(drawn: AcpmuxSnapshot, next: AcpmuxSnapshot): number {
  const before = drawn as unknown as Record<string, unknown>;
  const after = next as unknown as Record<string, unknown>;
  const keys = Object.keys(after);
  if (keys.length !== Object.keys(before).length) return -1;
  for (const key of keys) if (key !== "rows" && !Object.is(before[key], after[key])) return -1;
  if (streamingRowBlocked()) return -1;
  const at = textOnlyRow(drawn.rows, next.rows);
  return at >= 0 && drawsAsIs(drawn.rows[at]!) ? at : -1;
}
