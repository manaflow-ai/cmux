// What of a transcript row is open, read from the same stores its components open from, as one
// string. The transcript places a row at its last drawn height only while this string is the one it
// was drawn with (VirtualTranscript.tsx `DrawnHeight.open`): a height drawn with a run, a group, a
// call or a message open never places the row once the reader closed it (or the other way), which
// left a hole the size of the panel between activity rows (Leo, 2026-11-17: "why is there this big
// gap when i have shit expanded").
//
// The stores: the reader's disclosure choices (transcriptDisclosureModel.ts, which runs, groups and
// calls open by: ToolRun.tsx, ToolGroupRow.tsx), the messages they opened (incomingOpened.ts, which
// "Received N messages" and a received line open by: LaneNoticeBatch.tsx, IncomingMessageCard.tsx),
// and the row's own flags (`foldOpen`, a Worked-for line; `runOpen`, a run that starts open). The
// string changes whenever any of them changes for the row; it does not decide what is open (the
// components do, with their links and defaults), so it is never wrong about a change, only coarse.
import type { AcpmuxRow } from "../model";
import { inboxThreadKey } from "./inboxNotice";
import { messageOpened } from "./incomingOpened";
import { choicesNaming } from "./transcriptDisclosureModel";

/// The ids a row's disclosures are keyed under: its own, its calls', and the rows it groups.
function* keyedIds(row: AcpmuxRow): Generator<string> {
  yield row.id;
  for (const item of row.items ?? []) if (item.tool?.id) yield item.tool.id;
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
  const ids = [...keyedIds(row)];
  const grouped = members(row);
  if (grouped.length > 0) {
    let opened = "";
    for (const member of grouped) {
      opened += messageOpened(sessionId, member.id) ? "1" : "0";
      ids.push(...keyedIds(member));
    }
    flags += `|${opened}`;
  }
  const choices = choicesNaming(sessionId, ids);
  return choices === "" ? flags : `${flags}|${choices}`;
}

/// Whether a height drawn with open state `known.open` may place `row` now (VirtualTranscript.tsx's
/// placement): yes for a mounted row, which its observer and the motion's end (`settleMotion`)
/// measure in the state it is drawn in before the frame paints; out of the mounted range, where
/// nothing measures it again, only in the open state it was drawn in, else its estimate places it.
export function drawnOpenStateHolds(
  known: { open?: string },
  sessionId: string | undefined,
  row: AcpmuxRow,
  mounted: boolean,
): boolean {
  return mounted || (known.open ?? "") === rowOpenState(sessionId, row);
}
