import type { AcpmuxRow } from "../model";
import { groupId, runStretches, type RunStretch, type ToolGroup } from "./toolGroups";

/// A run of tool calls and thoughts between two pieces of text, in groups (toolGroups.ts). The
/// Codex-style runs fold a finished run (`foldRun`) of two or more entries under one summary line
/// (toolRunSummary.ts: "Read 6 files, ran 4 commands"), and a run that is one group under that
/// group's closed line ("Ran 3 commands"), so finished work is one click away between the
/// paragraphs; coordination cards stay in sight between such lines (`runStretches`). A run not
/// folded (`foldRun` unset) keeps each group and call on its own line.
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

/// The open state's key of a group's line: its kind and its first call's id, never its place, count
/// or words, so the line keeps the reader's choice while calls join it, its words change ("Ran 2
/// commands" to "Finished a background task and ran 4 commands") and its row is shaped anew (the
/// turn's end, a short aside that joins two rows). Undefined for an entry with no line of its own.
export function groupDisclosureKey(group: ToolGroup, index: number, rowId: string): string | undefined {
  if (group.type === "group") return `group:${group.kind}:${groupId(group.items) || `${rowId}:${index}`}`;
  if (group.type === "mcp") return `group:mcp:${group.items[0]!.tool!.id || `${rowId}:${index}`}`;
  return undefined;
}

/// The open state's key of a stretch's summary line: its first call's id, as a group's is, so a
/// run's line keeps the reader's choice when the row it sits in changes id (an ended turn's edits
/// row, two runs joined around an aside) or a card splits the run.
export function runDisclosureKey(stretch: Pick<RunStretch, "items" | "from">, rowId: string): string {
  const first = stretch.items.find((item) => item.tool)?.tool?.id;
  return first ? `run:${first}` : `run:${rowId}:${stretch.from}`;
}

/// A row's groups and runs, in a word: each stretch's fold, and each group's kind and size. It changes
/// when a call joins a group, groups two calls, splits a run or folds it, never as a call streams.
export function runShape(stretches: readonly Pick<RunStretch, "fold" | "groups">[]): string {
  let shape = "";
  for (const stretch of stretches) {
    shape += stretch.fold ? "F" : "|";
    for (const group of stretch.groups)
      shape += `${group.type}${"kind" in group ? group.kind : ""}${"items" in group ? group.items.length : 1},`;
  }
  return shape;
}
