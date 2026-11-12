// A run of background-task notifications folds into one line (Leo, 2026-11-02, on a chat that drew
// "Background task finished" four times, each with a lone "·" reply under it: "why do you still do
// these" and "should we improve the app then"). Two or more of them in a row, with nothing the
// person needs between them, draw as "4 background tasks finished"; a click opens the line to the
// rows exactly as they drew before. A notification the agent answered with something to say is no
// member: acpmux called its turn not quiet, so it has no line and its reply draws as it came.
//
// Members: a quiet background turn's line that has ended (backgroundTurns.ts), and a background
// shell that finished or stopped, noted where it ended (BackgroundTaskNote.tsx) or marked on the call
// that started it (CommandRow.tsx). A failed shell stays on its own row, in sight. Between members,
// quiet rows go with the run: a thought, a message sent to or received from another agent, a
// subagent's end, a reply that draws nothing, the rows of a member line the reader opened on its own
// (`inBackground`). Anything else ends it. Which row is which is one table, foldPolicy.ts.
//
// The line reuses the background turn's row kind, so it takes that line's height, spacing and look
// everywhere (model.ts, App.tsx); it carries `backgroundRun` instead of `background`. Its open state
// is the transcript's fold set, keyed by its first member, like a message run's line
// (messageRuns.ts). One pass over a turn's rows, beside foldMessageRuns: no work per token beyond the
// turn shaping already does.
import type { AcpmuxBackgroundRun, AcpmuxRow } from "../model";
import type { Translate } from "../i18n";
import { BACKGROUND_TURN } from "./backgroundTurns";
import { foldSpans, rowRoles, runLabelKey } from "./foldPolicy";
import type { Folds } from "./viewFolds";

export const BACKGROUND_RUN = "backgroundRun";

export const backgroundRunRowId = (firstId: string) => `${BACKGROUND_RUN}-${firstId}`;

/// `rows` with each run of two or more background-task notifications folded under one line: the
/// line alone while closed, the line and the run's rows while open (`expanded` holds the line's
/// id). Without such a run, `rows` itself. Which rows are members, which ride along and which end a
/// run is the fold policy's (foldPolicy.ts); this draws its spans.
///
/// Both looks of a background turn fold (backgroundTurnLook.experiment.ts). Inline, a quiet
/// background turn has no line of its own, so its members are the shells that finished: the line
/// reads as a tool call's, "14 background commands finished" (Leo, 2026-11-12: "this is prob pretty
/// obvious as fold candidates").
export function foldBackgroundRuns(rows: AcpmuxRow[], expanded: Folds): AcpmuxRow[] {
  if (rows.length < 2) return rows;
  const roles = rowRoles(rows, (row) => row.background?.id);
  const spans = foldSpans(roles);
  if (!spans.length) return rows;
  const out: AcpmuxRow[] = rows.slice(0, spans[0]!.from);
  spans.forEach((span, at) => {
    const folded = rows.slice(span.from, span.to);
    const first = folded[0]!;
    // Open under any member's key, as a message run is (messageRuns.ts): two runs a reply that draws
    // nothing joins, or a run whose first member changed, keep the open the reader gave one of them.
    // Its id is that key, so a click closes it by the same key. Keyed lookups, one per row.
    const opened = folded.find((row) => expanded.has(backgroundRunRowId(row.id)));
    const id = backgroundRunRowId((opened ?? first).id);
    const open = opened !== undefined;
    const { command, finished, stopped, scheduled, other, sent, received } = span.tallies;
    const run: AcpmuxBackgroundRun = {
      // A shell that completed is a finished task to the line's older words (`backgroundRunLabel`).
      finished: finished + command,
      stopped,
      scheduled,
      other,
      ...(command > 0 && { commands: command }),
      ...(sent > 0 && { sent }),
      ...(received > 0 && { received }),
      rows: folded.map((row) => row.id),
    };
    out.push({
      id,
      // Moves with every member's version and the open state: the memoized line and the height
      // cache compare versions only.
      version: folded.reduce((sum, row) => (sum * 31 + row.version) % 1_000_003, folded.length) * 2 + (open ? 1 : 0),
      at: first.at,
      kind: BACKGROUND_TURN,
      foldOpen: open,
      backgroundRun: run,
    });
    if (open) out.push(...folded);
    out.push(...rows.slice(span.to, spans[at + 1]?.from ?? rows.length));
  });
  return out;
}

/// The open background-run lines among a turn's rows `rows[start..end)`, which a cached turn
/// compares. A line's id is the member's it was opened under (`foldBackgroundRuns`).
export function openBackgroundRuns(rows: readonly AcpmuxRow[], start: number, end: number, expanded: Folds): string {
  if (expanded.size === 0) return "";
  let open = "";
  for (let at = start; at < end; at += 1) {
    const id = backgroundRunRowId(rows[at]!.id);
    if (expanded.has(id)) open += `${id} `;
  }
  return open;
}

/// The closed background-run line among `drawn` that folds the row `rowId` away, so Find or a link
/// opens it.
export function backgroundRunFoldFor(drawn: readonly AcpmuxRow[], rowId: string): string | undefined {
  for (const row of drawn)
    if (row.backgroundRun && !row.foldOpen && row.backgroundRun.rows.includes(rowId)) return row.id;
  return undefined;
}

/// The line's words, from the policy's table (foldPolicy.ts `RUN_LABELS`): "14 background commands
/// finished" when every member is a shell that completed, "4 background tasks finished" when every
/// member finished, else "5 background updates"; then the messages the rows it folded carried, as a
/// message run names them ("sent 2 messages, received 9 messages").
export function backgroundRunLabel(t: Translate, run: AcpmuxBackgroundRun): string {
  const n = run.finished + run.stopped + run.scheduled + run.other;
  const commands = run.commands ?? 0;
  const key = runLabelKey(
    "background",
    {
      command: commands,
      finished: run.finished - commands,
      stopped: run.stopped,
      scheduled: run.scheduled,
      other: run.other,
      sent: run.sent ?? 0,
      received: run.received ?? 0,
    },
    n,
  );
  const sent = run.sent ?? 0;
  const received = run.received ?? 0;
  return [
    t(key, { n }),
    ...(sent ? [sent === 1 ? t("messageRun.sent.one") : t("messageRun.sent.other", { n: sent })] : []),
    ...(received
      ? [received === 1 ? t("messageRun.received.one") : t("messageRun.received.other", { n: received })]
      : []),
  ].join(t("toolRun.separator"));
}
