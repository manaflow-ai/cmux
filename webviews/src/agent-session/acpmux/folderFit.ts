/// One listed row's words and what its row draws beside them (a worktree count, a worktree's
/// indent, a private repository's lock glyph), for the menu's width.
export type FitLine = { text: string; kind: "row" | "count" | "worktree" | "lock" };

/// The few lines that can be the widest: the longest by their letters, the room beside them counted
/// in letters too. Thousands of folders stay a handful of measured lines.
export function widestLines(lines: readonly FitLine[], keep = 6): FitLine[] {
  const reach = (line: FitLine) => line.text.length + FIT_KIND_LETTERS[line.kind];
  // One pass, the kept few in order: no sort of every folder on each render.
  const widest: FitLine[] = [];
  for (const line of lines) {
    if (widest.length === keep && reach(line) <= reach(widest[keep - 1]!)) continue;
    if (widest.some((kept) => kept.kind === line.kind && kept.text === line.text)) continue;
    const at = widest.findIndex((kept) => reach(kept) < reach(line));
    widest.splice(at === -1 ? widest.length : at, 0, line);
    if (widest.length > keep) widest.pop();
  }
  return widest;
}

/// About how many letters wide each kind's extra room is (composerLocation.css gives the real widths).
const FIT_KIND_LETTERS: Record<FitLine["kind"], number> = { row: 0, count: 7, worktree: 3, lock: 3 };
