// A group row's line totals, as Claude Code desktop puts them on a collapsed run ("Ran 5 commands,
// created notes.md +53"; Leo 2026-10-30: "i like claude code they put the number overarching
// too"): the lines its edits added in green, and the lines they removed in red when there are any,
// in the same marks a file's own row draws (WriteLabel.tsx, EditDiff.tsx).
import { toolFiles } from "../diff";
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type EditTotals = { additions: number; deletions: number };

/// Test probe: how many times a group counted its edits' lines. Unset in the app.
export const editTotalsProbe: { count?: () => void } = {};

/// The lines a group's calls added and removed, counted as the edited-files card counts them
/// (`toolFiles` with `known`: a Write over a file whose old contents are unknown adds nothing).
/// Undefined when no call carried a diff, so a group without edits draws no count.
export function editTotals(tools: readonly Tool[]): EditTotals | undefined {
  const files = toolFiles(tools, { known: true });
  if (!files.length) return undefined;
  let additions = 0;
  let deletions = 0;
  for (const file of files) {
    additions += file.additions;
    deletions += file.deletions;
  }
  return { additions, deletions };
}

/// The last count per group, under its last edit's snapshot: an entry lives as long as that
/// snapshot (a WeakMap, no cleanup needed).
const totalsCache = new WeakMap<Tool, { edits: Tool[]; totals: EditTotals | undefined }>();

/// A group's totals, counted again only when one of its edits changes. Items are immutable
/// snapshots (direct.ts replaces only the call a chunk changed), so a call streaming its output, a
/// command or a thought, leaves every edit as it was and the totals are reused: the per-render work
/// is an identity check per item, with no diff parsed again. A pure read of a module cache, so the
/// React Compiler still optimizes the rows that call it.
export function useEditTotals(items: readonly AcpmuxActivity[]): EditTotals | undefined {
  const edits: Tool[] = [];
  for (const item of items) if (item.tool?.diffs?.length) edits.push(item.tool);
  const last = edits[edits.length - 1];
  if (!last) return undefined;
  const prior = totalsCache.get(last);
  if (prior && prior.edits.length === edits.length && edits.every((tool, at) => tool === prior.edits[at]))
    return prior.totals;
  editTotalsProbe.count?.();
  const totals = editTotals(edits);
  totalsCache.set(last, { edits, totals });
  return totals;
}

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
