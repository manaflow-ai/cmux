// The one gate every transcript draw passes through (direct.ts `emitNow`): a chat's rows on screen
// never go back to an older copy of it, whichever source drew that copy.
//
// A page draws a chat from many sources: its own kept tail, the app host's copy, the Mac's peer
// copy, a carried client's rows, an attach page, the live stream. Each fix so far stopped one of
// them from drawing an older copy over a newer one (#41552, #41540, #41700), and the next source
// flipped the chat again (Leo, 2026-11-12: "where is the better architecture"; "the chat literally
// only works 1% of the time now if you consider the appearance"). The rule lives here instead,
// once, at the boundary to the view: a snapshot of a chat whose newest record is older than the
// newest one this page has already shown of the same chat keeps the rows already shown. The client
// goes on folding what it reads; the view only moves forward. A new client on the same page (a
// reconnect makes one) passes the same gate, because the gate is the page's, not the client's.
//
// A chat made again under the same id (acpmux's `createdAt` generation) starts its seqs over, so a
// known generation that differs from the shown one starts the chat over here too.
import type { AcpmuxRow } from "./model";

type Shown = { generation: number | undefined; through: number; rows: AcpmuxRow[] };

/// Chats whose shown rows the page holds, least recently drawn first. The selected chat and the few
/// a person switches between: a chat switched back to draws its kept tail first (tailCache.ts), and
/// the gate refuses that tail only when it is older than what was on screen.
const SHOWN_CHATS = 8;
const shown = new Map<string, Shown>();

/// How many snapshots the gate kept the shown rows for, since the page loaded: the detector a test
/// and a perf capture read (a number that grows is a source drawing an older copy).
export const transcriptGateStats = { refused: 0 };

/// A row this page made with no record behind it yet (a prompt sending or failed): it goes with the
/// shown rows when an older copy is refused, so what the person just sent stays on screen.
function local(row: AcpmuxRow): boolean {
  return row.kind === "user" && (row.pending === true || row.failed === true || row.delivery !== undefined);
}

/// The rows to draw for `sessionId`, whose client has folded records through `through` (its newest
/// record's seq; 0 for none yet) of chat generation `generation`.
export function passTranscript(
  sessionId: string | undefined,
  generation: number | undefined,
  through: number,
  rows: AcpmuxRow[],
): AcpmuxRow[] {
  if (!sessionId) return rows;
  const before = shown.get(sessionId);
  const sameChat =
    before !== undefined &&
    (before.generation === undefined || generation === undefined || before.generation === generation);
  if (before && sameChat && through < before.through) {
    transcriptGateStats.refused += 1;
    const held = new Set(before.rows.map((row) => row.id));
    const sent = rows.filter((row) => local(row) && !held.has(row.id));
    return sent.length ? [...before.rows, ...sent] : before.rows;
  }
  shown.delete(sessionId);
  shown.set(sessionId, { generation: generation ?? (sameChat ? before?.generation : undefined), through, rows });
  if (shown.size > SHOWN_CHATS) shown.delete(shown.keys().next().value!);
  return rows;
}

export function resetTranscriptGateForTests(): void {
  shown.clear();
  transcriptGateStats.refused = 0;
}
