import { createContext, type ReactNode } from "react";
import { countsFailed, isRunning } from "../conversation/toolGroups";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { SUBAGENTS } from "../subagents/subagentFold";

/// Rows mounted at first, and how many more each scroll to the top adds.
export const WINDOW = 60;
/// The rows mounted at first, bounded at both ends: `end` undefined follows the newest row (the
/// newest window, which grows as rows arrive); a window around an anchor row ends WINDOW rows on, so
/// opening a task early in a long transcript mounts no more than one window either way.
export type Range = { start: number; end?: number };

/// The most rows mounted at once while the reader pages up or down: one window gained, one kept.
export const MOUNTED = 2 * WINDOW;

export function windowRange(rows: readonly { id: string }[], anchor?: string): Range {
  const newest = Math.max(0, rows.length - WINDOW);
  const at = anchor === undefined ? -1 : rows.findIndex((row) => row.id === anchor);
  if (at < 0) return { start: newest };
  const start = Math.min(newest, Math.max(0, at - Math.floor(WINDOW / 4)));
  const end = start + WINDOW;
  return end >= rows.length ? { start } : { start, end };
}

/// The window over `next` that mounts what `range` mounted over `prev`, when the same rows draw as other
/// blocks (two work rows folded into one run as a call streams in): each end moves to the block that
/// now holds its row, so regrouping never moves the window. A start whose row is gone takes the newest
/// window.
export function carryRange(prev: readonly TranscriptBlock[], next: readonly TranscriptBlock[], range: Range): Range {
  const holder = new Map<string, number>();
  next.forEach((block, index) => {
    if (block.type === "row") holder.set(block.id, index);
    else for (const row of block.rows) holder.set(row.id, index);
  });
  const at = (index: number) => {
    const block = prev[index];
    return block === undefined ? undefined : holder.get(block.id);
  };
  const start = at(Math.min(range.start, prev.length - 1));
  if (start === undefined) return windowRange(next);
  if (range.end === undefined || range.end >= prev.length) return { start };
  const end = at(range.end - 1);
  return end === undefined || end + 1 >= next.length ? { start } : { start, end: end + 1 };
}

/// What a nested agent's line in a transcript does (BackgroundTasksPanel.tsx provides it): it opens
/// that agent's own transcript, and while it runs it carries the agent's stop button, so an agent at
/// any depth opens and stops from the panel.
export const NestedAgents = createContext<{
  open?(agentId: string): void;
  stop?(agentId: string, name: string): ReactNode;
}>({});

/// What a transcript draws, in order: a row on its own (a reply, the prompt, a nested agent, a lone
/// call), or a run, the stretch of work rows between two of those folded under one line (Claude Code's
/// drill-in: "Ran 14 commands, read a file and created a file", which opens to its steps).
export type TranscriptBlock =
  | { type: "row"; id: string; row: AcpmuxRow }
  | {
      type: "run";
      /// Its first row's id: where it starts, for a key.
      id: string;
      rows: AcpmuxRow[];
      /// Every step of its rows, thoughts and calls, in order.
      items: AcpmuxActivity[];
      calls: number;
      failed: number;
      /// A call in it still runs.
      running: boolean;
    };

/// A row that is only work: tool calls and thoughts, no reply, prompt or nested agent of its own.
const isWork = (row: AcpmuxRow) =>
  !(row.kind === "assistant" && row.text) &&
  !(row.kind === "user" && row.text) &&
  row.kind !== SUBAGENTS &&
  (row.items?.length ?? 0) > 0;

/// The blocks `rows` draw as: each stretch of work rows with at least `fold` tool calls is one run;
/// a shorter stretch keeps its rows. `fold` 0 folds nothing (every call on its own line).
export function transcriptBlocks(rows: readonly AcpmuxRow[], fold: number): TranscriptBlock[] {
  const blocks: TranscriptBlock[] = [];
  let stretch: AcpmuxRow[] = [];
  const flush = () => {
    if (stretch.length === 0) return;
    const items = stretch.flatMap((row) => row.items ?? []);
    const tools = items.flatMap((item) => (item.kind === "tool" && item.tool ? [item.tool] : []));
    if (fold > 0 && tools.length >= fold)
      blocks.push({
        type: "run",
        id: stretch[0]!.id,
        rows: stretch,
        items,
        calls: tools.length,
        failed: tools.filter(countsFailed).length,
        running: tools.some(isRunning),
      });
    else for (const row of stretch) blocks.push({ type: "row", id: row.id, row });
    stretch = [];
  };
  for (const row of rows) {
    if (isWork(row)) {
      stretch.push(row);
      continue;
    }
    flush();
    blocks.push({ type: "row", id: row.id, row });
  }
  flush();
  return blocks;
}

/// The fewest calls a stretch folds at, by the transcript's look (transcriptRuns.experiment.ts).
export const runFold = (look: string): number => (look === "lines" ? 0 : look === "every" ? 1 : 2);
