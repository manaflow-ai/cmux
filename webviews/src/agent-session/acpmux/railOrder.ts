// The compact model menu's harness rail (QuickModelMenu): the harnesses this Mac can run come first,
// in their own order, then the ones it does not have (first-run audit row 12, cmux-shots/first-run at
// 2:35: on a Mac with no agent the rail was 15 marks in catalog order, Claude Code and Codex among
// installers, and a new user had no way to tell which mark would start something). The rail stays
// marks only (each tab's name is its tooltip and accessible name), so the order is the cue.

/** `entries` with every installed one ahead of every missing one; each group keeps its order. */
export function installedFirst<T extends { notInstalled?: boolean }>(entries: readonly T[]): T[] {
  return [...entries.filter((entry) => !entry.notInstalled), ...entries.filter((entry) => entry.notInstalled)];
}
