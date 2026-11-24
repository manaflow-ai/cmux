// A group row's line totals, as Claude Code desktop puts them on a collapsed run ("Ran 5 commands,
// created notes.md +53"; Leo 2026-10-30: "i like claude code they put the number overarching
// too"): the lines its edits added in green, and the lines they removed in red when there are any,
// in the same marks a file's own row draws (WriteLabel.tsx, EditDiff.tsx).
import { type EditTotals } from "./editCountsModel";
/// "+53", or "+12 -3": the removed count only when the edits removed lines. An edits group keeps
/// "-0" (`zero`), as its file rows and the edited-files card read ("Edited App.tsx +12 -0").
export function EditCounts({ totals, zero = false }: { totals: EditTotals; zero?: boolean }) {
  return (
    <span className="cv-tool__counts">
      <span className="cv-edit-diff__add">+{totals.additions}</span>
      {(zero || totals.deletions > 0) && <span className="cv-edit-diff__del">-{totals.deletions}</span>}
    </span>
  );
}
