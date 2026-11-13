// A run of background-task notifications folds into one line (Leo, 2026-11-02, on a chat that drew
// "Background task finished" four times, each with a lone "·" reply under it: "why do you still do
// these" and "should we improve the app then"). Two or more of them in a row, with nothing the
// person needs between them, draw as "4 background tasks finished"; a click opens the line to the
// rows exactly as they drew before. A notification the agent answered with something to say is no
// member: acpmux called its turn not quiet, so it has no line and its reply draws as it came.
//
// Members: a quiet background turn's line that has ended (backgroundTurns.ts), and a background
// shell's end noted where it ended (BackgroundTaskNote.tsx), finished, stopped or failed. A failed
// shell joins the run and the line counts it ("21 background commands finished, 2 failed"), so a
// failure is still named in sight. Between members, a reply that draws nothing (visibleMessage.ts: empty or
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
//
// Shell ends fold in every look of background turns (backgroundTurnLook.experiment.ts). With the
// default look, where a background turn's calls draw inline, only the shell ends are members: a chat
// with dozens of subagents drew one "Background command completed" row per subagent shell, dozens in
// a row (Leo, 2026-11-12: "Holy crap, there are way too many [waits] here... this looks like a
// degenerate [state], bro"). Now they are one line, "23 background commands finished".
import type { AcpmuxBackgroundRun, AcpmuxRow } from "../model";
import type { Translate } from "../i18n";
import { experimentArm } from "../../../experiments/experiment";
import { backgroundTurnLook, backgroundTurnsInline } from "./backgroundTurnLook.experiment";
import { BACKGROUND_TURN, backgroundWeight } from "./backgroundTurns";
import type { Folds } from "./viewFolds";
import { isVisiblyEmptyMessage } from "./visibleMessage";

export const BACKGROUND_RUN = "backgroundRun";

export const backgroundRunRowId = (firstId: string) => `${BACKGROUND_RUN}-${firstId}`;

type MemberKind = "finished" | "stopped" | "failed" | "scheduled" | "other";

/// What a member adds to its run's line, or undefined for a row that is no member. `inline`: the
/// default look, where background turns draw no line, so only shell ends are members.
function memberKind(row: AcpmuxRow, inline: boolean): MemberKind | undefined {
  if (row.kind === BACKGROUND_TURN) {
    if (inline) return undefined;
    const turn = row.background;
    if (!turn || turn.running || turn.quiet !== true || backgroundWeight(turn)) return undefined;
    if (turn.trigger === "task_notification") return "finished";
    return turn.trigger === "scheduled" ? "scheduled" : "other";
  }
  if (row.kind === "backgroundTask") {
    const state = row.backgroundTask?.state;
    if (state === "completed") return "finished";
    if (state === "stopped") return "stopped";
    if (state === "failed") return "failed";
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
  // Inline, a background turn's calls draw as they came, as a tool call's row does
  // (backgroundTurnLook.experiment.ts); a run of shell ends still folds.
  const inline = backgroundTurnsInline(experimentArm(backgroundTurnLook));
  let out: AcpmuxRow[] | undefined;
  let index = 0;
  while (index < rows.length) {
    const first = rows[index]!;
    if (!memberKind(first, inline)) {
      out?.push(first);
      index += 1;
      continue;
    }
    const counts = { finished: 0, stopped: 0, failed: 0, scheduled: 0, other: 0 };
    let commands = 0;
    const lines = new Set<string>();
    let end = index;
    let last = index;
    for (; end < rows.length; end += 1) {
      const row = rows[end]!;
      const kind = memberKind(row, inline);
      if (kind) {
        counts[kind] += 1;
        if (row.kind === "backgroundTask") commands += 1;
        if (row.background) lines.add(row.background.id);
        last = end;
      } else if (ownedBy(row, lines)) last = end;
      else if (!bareReply(row)) break;
    }
    // Bare replies after the run's last member are not the run's: they draw (nothing) as before.
    end = last + 1;
    const members = counts.finished + counts.stopped + counts.failed + counts.scheduled + counts.other;
    if (members < 2) {
      out?.push(...rows.slice(index, end));
      index = end;
      continue;
    }
    out ??= rows.slice(0, index);
    const folded = rows.slice(index, end);
    // Open under any member's key, as a message run is (messageRuns.ts): two runs a reply that draws
    // nothing joins, or a run whose first member changed, keep the open the reader gave one of them.
    // Its id is that key, so a click closes it by the same key. Keyed lookups, one per member.
    const opened = folded.find((row) => expanded.has(backgroundRunRowId(row.id)));
    const id = backgroundRunRowId((opened ?? first).id);
    const open = opened !== undefined;
    const run: AcpmuxBackgroundRun = { ...counts, commands, rows: folded.map((row) => row.id) };
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

/// The line's words. A run of shell ends only: "23 background commands finished" (a stopped one
/// counts as ended), "21 background commands finished, 2 failed", or "2 background commands failed".
/// Else "4 background tasks finished" when every member finished, else "5 background updates" (a
/// stopped shell, a scheduled check or another kind of background turn among them), with the failed
/// count after it when one failed.
export function backgroundRunLabel(t: Translate, run: AcpmuxBackgroundRun): string {
  const failed = run.failed ?? 0;
  const n = run.finished + run.stopped + failed + run.scheduled + run.other;
  const ended = n - failed;
  if (run.commands === n) {
    if (failed === 0) return t("backgroundRun.commands", { n });
    if (ended === 0) return t("backgroundRun.commandsAllFailed", { n: failed });
    return t("backgroundRun.commandsFailed", { n: ended, failed });
  }
  const words = n === run.finished ? t("backgroundRun.finished", { n }) : t("backgroundRun.updates", { n });
  return failed ? `${words}, ${t("backgroundRun.failedCount", { n: failed })}` : words;
}
