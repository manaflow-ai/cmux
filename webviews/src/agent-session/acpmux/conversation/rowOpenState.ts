// What of a transcript row is open, read from the same stores its components open from, as one
// string: the row's state signature (cmuxterm-hq docs/design/transcript-motion-model.md rule 5, "A
// placed height belongs to the state it was drawn in: (id, rev, width, state signature). The
// estimate reads the same state signature as the DOM."). The transcript places a row at a drawn
// height, and reuses a remembered estimate, only while this string is the one it was taken with
// (VirtualTranscript.tsx `DrawnHeight.open`, model.ts `RowHeights`): a height drawn with a run, a
// group, a call, a thought, a card or a message open never places the row once the reader closed it
// (or the other way), which left a hole between activity rows (Leo, 2026-11-17: "why is there this
// big gap when i have shit expanded").
//
// The stores: the reader's disclosure choices (transcriptDisclosureModel.ts, which runs, groups,
// calls and prompts open by), the messages they opened (incomingOpened.ts, which "Received N
// messages" and a received line open by), the thoughts they opened (thoughtChoices.ts), the edited
// files card (turnChanges/openStore.ts), and the row's own flags (`foldOpen`, a Worked-for line;
// `runOpen`, a run that starts open). The string changes whenever any of them changes for the row;
// it does not decide what is open (the components do, with their links and defaults), so it is never
// wrong about a change, only coarse.
import type { AcpmuxRow } from "../model";
import { cardOpen } from "../turnChanges/openStore";
import { inboxThreadKey } from "./inboxNotice";
import { messageOpened } from "./incomingOpened";
import { thoughtChoicesNaming } from "./thoughtChoices";
import { choicesNaming } from "./transcriptDisclosureModel";

/// The ids a row's disclosures are keyed under: its own and its calls'.
function keyedIds(row: AcpmuxRow, into: string[]): void {
  into.push(row.id);
  for (const item of row.items ?? []) if (item.tool?.id) into.push(item.tool.id);
}

/// The rows a grouping row draws as lines of its own, each opening by its id.
function members(row: AcpmuxRow): readonly AcpmuxRow[] {
  return row.laneNoticeBatch?.rows ?? row.pendingMessages?.displayRows ?? row.pendingMessages?.rows ?? [];
}

/// What of `row` in chat `sessionId` is open (see above). "" for a row with nothing it can open set.
export function rowOpenState(sessionId: string | undefined, row: AcpmuxRow): string {
  let flags = "";
  if (row.foldOpen) flags += "w";
  if (row.runOpen) flags += "r";
  if (messageOpened(sessionId, row.id)) flags += "m";
  if (row.inboxThread && messageOpened(sessionId, inboxThreadKey(row.id, row.inboxThread.threadId))) flags += "t";
  if (cardOpen(row.id)) flags += "c";
  const ids: string[] = [];
  keyedIds(row, ids);
  const grouped = members(row);
  if (grouped.length > 0) {
    let opened = "";
    for (const member of grouped) {
      opened += messageOpened(sessionId, member.id) ? "1" : "0";
      keyedIds(member, ids);
    }
    flags += `|${opened}`;
  }
  const choices = choicesNaming(sessionId, ids);
  const thoughts = thoughtChoicesNaming(row.id);
  return `${flags}${choices === "" ? "" : `|${choices}`}${thoughts === "" ? "" : `|${thoughts}`}`;
}

/// Whether a height drawn with open state `known.open` may place `row` now (VirtualTranscript.tsx's
/// placement): yes for a mounted row, which its observer and the motion's end (`settleMotion`)
/// measure in the state it is drawn in before the frame paints; out of the mounted range, where
/// nothing measures it again, only in the open state it was drawn in, else its estimate (which reads
/// the same stores) places it.
export function drawnOpenStateHolds(
  known: { open?: string },
  sessionId: string | undefined,
  row: AcpmuxRow,
  mounted: boolean,
): boolean {
  return mounted || (known.open ?? "") === rowOpenState(sessionId, row);
}
