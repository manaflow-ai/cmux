// Which snapshots the pane draws around (HOT PATH AUDIT area F, row W1): a frame that only grew
// the streaming reply's text, or that text and one running command's output.
import type { AcpmuxSnapshot } from "./model";
import { keptPrefix } from "./conversation/prefixFlatMap";
import { sameButRows, toolOutputAt } from "./liveToolOutput";
import { drawsAsIs, streamedText, streamingRowBlocked, textOnlyRow } from "./streamingRow";

/// What a snapshot changed when it only streamed (HOT PATH AUDIT area F, row W1), else undefined:
/// the streaming reply's row whose text grew (`text`), and at most one running command whose output
/// grew in the same frame (`call`, liveToolOutput.ts `toolOutputAt`). The client draws a frame's
/// events as one snapshot (direct.ts `emitInFrame`), so a reply streaming beside a running command
/// changes both rows in each: told one row at a time, every such frame redrew the pane, the reply's
/// content and the transcript (composer-typing.bench.ts L1: 459 pane renders in a 500-key run).
///
/// The rows are compared with `received`, the snapshot before this one: every snapshot since the
/// pane drew `drawn` went around it through a store that holds what it changed, so the pane's draw
/// plus those stores is `received`. The reply's row is also compared with the row the pane drew, as
/// streamingRow.ts draws it from that row. Every other field compares by identity (or as
/// liveToolOutput.ts `sameButRows` reads the client's per-snapshot projections): the client keeps the
/// same objects while they do not change (direct.ts `publishedSummary`, `NO_CATALOG`, subagentFold.ts
/// `views`), so this is O(fields + rows changed), with no serialization. Drawn only while the
/// transcript draws the reply's row as the client holds it (`drawsAsIs`) and no view that reads the
/// pane's rows is open (`streamingRowBlocked`); a command's output only while no pane draw is pending.
export function streamedOnly(
  drawn: AcpmuxSnapshot,
  received: AcpmuxSnapshot | undefined,
  next: AcpmuxSnapshot,
  drawPending = false,
): { text: number; call?: { id: string; output: string; before: string | undefined } } | undefined {
  if (streamingRowBlocked() || !sameButRows(drawn, next)) return undefined;
  const previous = received ?? drawn;
  if (previous !== drawn && !sameButRows(previous, next)) return undefined;
  const at = textOnlyRow(previous.rows, next.rows);
  if (at >= 0) return drewAsIs(drawn, next, at) ? { text: at } : undefined;
  // The reply's text and one command's output, in one frame.
  if (drawPending || previous.rows.length !== next.rows.length) return undefined;
  const kept = keptPrefix(previous.rows, next.rows);
  let text = -1;
  let call: { id: string; output: string; before: string | undefined } | undefined;
  for (let index = next.rows.length - 1; index >= kept; index -= 1) {
    const before = previous.rows[index]!;
    const after = next.rows[index]!;
    if (before === after) continue;
    if (text < 0 && streamedText(before, after)) text = index;
    else if (!call && (call = toolOutputAt(previous, next, index))) continue;
    else return undefined;
  }
  return text >= 0 && call && drewAsIs(drawn, next, text) ? { text, call } : undefined;
}

/// Whether the pane drew the streaming reply at `at` as `next` grows it: the same row but for its
/// text, which only grew, and the transcript drew it as the client held it.
function drewAsIs(drawn: AcpmuxSnapshot, next: AcpmuxSnapshot, at: number): boolean {
  const row = drawn.rows[at];
  if (!row || drawn.rows.length !== next.rows.length) return false;
  return streamedText(row, next.rows[at]!) && drawsAsIs(row);
}
