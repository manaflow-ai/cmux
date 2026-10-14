import type { AcpmuxRow } from "../model";

/// The transcript without the tool calls a permission ask waits on (`pendingToolCalls`): while it
/// waits, the ask's row names the call, so the command is drawn once (Leo 2026-10-14: the chat
/// showed "Ran <command>" over a card that repeated it). Answered, the call is back in its place.
export function withoutAskedCalls(rows: AcpmuxRow[], asked: ReadonlySet<string>): AcpmuxRow[] {
  if (asked.size === 0) return rows;
  let changed = false;
  const kept: AcpmuxRow[] = [];
  for (const row of rows) {
    const items = row.items?.filter((item) => !(item.tool && asked.has(item.tool.id)));
    if (!items || items.length === row.items?.length) {
      kept.push(row);
      continue;
    }
    changed = true;
    // A half version: never one the row reaches by itself, so the whole row draws again when the
    // ask is answered.
    if (items.length > 0) kept.push({ ...row, items, version: row.version + 0.5 });
  }
  return changed ? kept : rows;
}
