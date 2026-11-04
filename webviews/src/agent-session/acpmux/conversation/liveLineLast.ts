// The running turn's live line ("Thinking 18s · 1m 23s total · 3.2K tokens") is always the
// transcript's last row while the turn runs. What the page adds after the turn's own rows (the group
// of other sessions' messages the agent has not read yet, a guest's held prompt, a `/btw` aside)
// arrived mid-turn, so it draws above the line, never under it (Leo, 2026-11-03: the live line
// rendered above a newer incoming agent message, so it was not last). turns.ts already keeps the
// line under the turn's own held prompts (`shapedTurn`) and shellRuns.ts `insertByTime` under the
// page's shell rows; this keeps it there for the rows App.tsx appends after both.
//
// Cost: a look at the last few rows. The line is the turn's last row, so only rows appended after
// it are walked; none means the same array back.
import type { AcpmuxRow } from "../model";
import { ACTIVITY_LINE, THINKING, WORKING } from "./turns";

/// How far from the end the line is looked for: the rows App.tsx appends after the turn's rows
/// (the waiting group, a guest's prompts, asides) are a handful, never a page.
const TAIL = 32;

/// The running turn's line drawn as its last row (turns.ts `below`).
export const isLiveLine = (row: AcpmuxRow) =>
  row.below === true && (row.kind === THINKING || row.kind === WORKING || row.kind === ACTIVITY_LINE);

/// `rows` with the running turn's live line moved to the end; the same array when it already is
/// last or there is none.
export function liveLineLast<T extends AcpmuxRow>(rows: T[]): T[] {
  const last = rows.length - 1;
  if (last < 1 || isLiveLine(rows[last]!)) return rows;
  for (let at = last - 1; at >= Math.max(0, last - TAIL); at -= 1) {
    const row = rows[at]!;
    if (!isLiveLine(row)) continue;
    return [...rows.slice(0, at), ...rows.slice(at + 1), row];
  }
  return rows;
}
