// Where a chat's prompts, turn summaries and edited-files rows are, for the pane's counts that
// read the whole chat (the folder-trust ask's prompt count, the ended edit turn). Kept across
// snapshots: only the rows after the first that differs from the previous snapshot's (by object)
// are read again, so a long chat's stream reads its last rows alone.
import { endsTurn } from "./diff";
import type { AcpmuxRow } from "./model";

export type RowMarks = {
  rows: readonly AcpmuxRow[];
  prompts: number[];
  summaries: number[];
  editedFiles: number[];
};

const MARKED = ["user", "turnSummary", "editedFiles"] as const;

export function markRows(rows: readonly AcpmuxRow[], previous?: RowMarks): RowMarks {
  let from = 0;
  if (previous)
    while (from < rows.length && from < previous.rows.length && rows[from] === previous.rows[from]) from += 1;
  const before = (indexes: number[] | undefined) => {
    if (!indexes) return [];
    let keep = indexes.length;
    while (keep > 0 && indexes[keep - 1]! >= from) keep -= 1;
    return indexes.slice(0, keep);
  };
  const marks: RowMarks = {
    rows,
    prompts: before(previous?.prompts),
    summaries: before(previous?.summaries),
    editedFiles: before(previous?.editedFiles),
  };
  const lists = [marks.prompts, marks.summaries, marks.editedFiles];
  for (let index = from; index < rows.length; index += 1) {
    const row = rows[index]!;
    const at = MARKED.indexOf(row.kind as (typeof MARKED)[number]);
    // The summary of a part a Send now cancelled does not end the turn (diff.ts endsTurn): the
    // turn goes on, and its checkpoint pair exists only once it ends.
    if (at >= 0 && (row.kind !== "turnSummary" || endsTurn(row))) lists[at]!.push(index);
  }
  return marks;
}

/// The id of the last edited-files row when a summary that ends its turn follows it.
export function endedEditRow(marks: RowMarks): string | undefined {
  const edit = marks.editedFiles.at(-1);
  if (edit === undefined) return undefined;
  return (marks.summaries.at(-1) ?? -1) > edit ? marks.rows[edit]!.id : undefined;
}
