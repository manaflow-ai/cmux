import type { AcpmuxRow } from "../model";
import { runStretches, type ToolGroup } from "./toolGroups";

/// A run of tool calls and thoughts between two pieces of text, in groups (toolGroups.ts). The
/// Codex-style runs (Debug toggle `agentPane.debug.codexToolRuns`, on by default) fold a finished
/// run (`foldRun`) of two or more entries under one summary line (toolRunSummary.ts: "Read 6 files,
/// ran 4 commands"), and a run that is one group under that group's closed line ("Ran 3 commands"),
/// so finished work is one click away between the paragraphs; coordination cards stay in sight
/// between such lines (`runStretches`). Off, each group and call keeps its own line.
/// Whether the whole run folds under one summary line.
export function shouldFoldToolRun(row: AcpmuxRow, groups: readonly ToolGroup[]): boolean {
  const stretches = runStretches(row, groups);
  return stretches.length === 1 && stretches[0]!.fold;
}

/// How many thoughts come before each entry of a run. A thought keeps its number as calls arrive
/// (a run only grows at its end, and grouping keeps the order), so its open state stays with it when
/// a call that finished joins it to a group (Codex review of #24075).
export function thoughtIds(groups: readonly ToolGroup[]): number[] {
  let thoughts = 0;
  return groups.map((group) => {
    const before = thoughts;
    const items = "items" in group ? group.items : [group.item];
    thoughts += items.filter((item) => !item.tool && item.kind !== "note").length;
    return before;
  });
}
