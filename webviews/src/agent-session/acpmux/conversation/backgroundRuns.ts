// A run of background-task notifications folds into one line (Leo, 2026-11-02, on a chat that drew
// "Background task finished" four times, each with a lone "·" reply under it: "why do you still do
// these" and "should we improve the app then"). Two or more of them in a row, with nothing the
// person needs between them, draw as "4 background tasks finished"; a click opens the line to the
// rows exactly as they drew before. A notification the agent answered with something to say is no
// member: acpmux called its turn not quiet, so it has no line and its reply draws as it came.
//
// Members: a quiet background turn's line that has ended (backgroundTurns.ts), and a background
// shell's end noted where it ended (BackgroundTaskNote.tsx), finished or stopped. A failed shell stays
// on its own row, in sight. Between members, a reply that draws nothing (visibleMessage.ts: empty or
// a lone period) and the rows of a member line the reader
// opened on its own (`inBackground`) go with the run. Anything else ends it. A line acpmux weighed
// (backgroundTurns.ts `backgroundWeight`: a result its call could not carry, a failure) names its
// own task and is no member either.
//
// The line reuses the background turn's row kind, so it takes that line's height, spacing and look
// everywhere (model.ts, App.tsx); it carries `backgroundRun` instead of `background`. Its open state
// is the transcript's fold set, keyed by its first member, like a message run's line
// (messageRuns.ts). One pass over a turn's rows, beside foldMessageRuns: no work per token beyond the
// turn shaping already does.
import type { AcpmuxBackgroundRun, AcpmuxRow } from "../model";
import type { Translate } from "../i18n";
import { BACKGROUND_TURN, backgroundWeight } from "./backgroundTurns";
import type { Folds } from "./viewFolds";
import { isVisiblyEmptyMessage } from "./visibleMessage";

export const BACKGROUND_RUN = "backgroundRun";

export const backgroundRunRowId = (firstId: string) => `${BACKGROUND_RUN}-${firstId}`;

/// What a member adds to its run's line, or undefined for a row that is no member.
function memberKind(row: AcpmuxRow): "finished" | "stopped" | "scheduled" | "other" | undefined {
  if (row.kind === BACKGROUND_TURN) {
    const turn = row.background;
    if (!turn || turn.running || turn.quiet !== true || backgroundWeight(turn)) return undefined;
    if (turn.trigger === "task_notification") return "finished";
    return turn.trigger === "scheduled" ? "scheduled" : "other";
  }
  if (row.kind === "backgroundTask") {
    const state = row.backgroundTask?.state;
    if (state === "completed") return "finished";
    if (state === "stopped") return "stopped";
  }
  return undefined;
}

/// A row of a member line the reader opened (`lines` holds the members' background turn ids): it
/// goes with the run, also after its last member, so closing the run hides it with its line.
const ownedBy = (row: AcpmuxRow, lines: ReadonlySet<string>) =>
  row.inBackground !== undefined && lines.has(row.inBackground);

/// A reply between members that draws nothing goes with the run without counting.
const bareReply = (row: AcpmuxRow) => row.kind === "assistant" && !row.streaming && isVisiblyEmptyMessage(row);

/// `rows` with each run of two or more background-task notifications folded under one line: the
/// line alone while closed, the line and the run's rows while open (`expanded` holds the line's
/// id). Without such a run, `rows` itself.
export function foldBackgroundRuns(rows: AcpmuxRow[], expanded: Folds): AcpmuxRow[] {
  let out: AcpmuxRow[] | undefined;
  let index = 0;
  while (index < rows.length) {
    const first = rows[index]!;
    if (!memberKind(first)) {
      out?.push(first);
      index += 1;
      continue;
    }
    const counts = { finished: 0, stopped: 0, scheduled: 0, other: 0 };
    const lines = new Set<string>();
    let end = index;
    let last = index;
    for (; end < rows.length; end += 1) {
      const row = rows[end]!;
      const kind = memberKind(row);
      if (kind) {
        counts[kind] += 1;
        if (row.background) lines.add(row.background.id);
        last = end;
      } else if (ownedBy(row, lines)) last = end;
      else if (!bareReply(row)) break;
    }
    // Bare replies after the run's last member are not the run's: they draw (nothing) as before.
    end = last + 1;
    const members = counts.finished + counts.stopped + counts.scheduled + counts.other;
    if (members < 2) {
      out?.push(...rows.slice(index, end));
      index = end;
      continue;
    }
    out ??= rows.slice(0, index);
    const folded = rows.slice(index, end);
    const id = backgroundRunRowId(first.id);
    const open = expanded.has(id);
    const run: AcpmuxBackgroundRun = { ...counts, rows: folded.map((row) => row.id) };
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
    index = end;
  }
  return out ?? rows;
}

/// The open background-run lines among a turn's rows `rows[start..end)`, which a cached turn
/// compares. A line's id is its first member's.
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

/// The line's words: "4 background tasks finished" when every member finished, else "5 background
/// updates" (a stopped shell, a scheduled check or another kind of background turn among them).
export function backgroundRunLabel(t: Translate, run: AcpmuxBackgroundRun): string {
  const n = run.finished + run.stopped + run.scheduled + run.other;
  return n === run.finished ? t("backgroundRun.finished", { n }) : t("backgroundRun.updates", { n });
}
