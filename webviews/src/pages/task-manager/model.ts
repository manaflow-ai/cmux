// The Task Manager page's pure rules: a column's order, the selection across samples, the PID
// column's text and whether Kill Process is on. No DOM, no host.
import type { SortKey, SortOrder, TaskManagerRow } from "./types";

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

function compare(key: SortKey, a: TaskManagerRow, b: TaskManagerRow): number {
  switch (key) {
    case "task":
      return collator.compare(a.task, b.task);
    case "name":
      return collator.compare(a.name, b.name);
    case "pid":
      // Equal pids on two machines tie and keep the app's order, as the SwiftUI table's did.
      return a.pid - b.pid;
    case "cpu":
      // No value yet sorts as zero, as the SwiftUI table did.
      return (a.cpu ?? 0) - (b.cpu ?? 0);
    case "memory":
      return a.memoryBytes - b.memoryBytes;
  }
}

/** `rows` in `order` (stable: equal rows keep the app's order); none keeps the app's order. */
export function sortRows(rows: readonly TaskManagerRow[], order: SortOrder | null): TaskManagerRow[] {
  if (!order) return [...rows];
  const sign = order.ascending ? 1 : -1;
  return rows
    .map((row, index) => ({ row, index }))
    .sort((a, b) => sign * compare(order.key, a.row, b.row) || a.index - b.index)
    .map(({ row }) => row);
}

/** A header click: the same column flips its direction, another column sorts ascending. */
export function nextOrder(current: SortOrder | null, key: SortKey): SortOrder {
  return current?.key === key ? { key, ascending: !current.ascending } : { key, ascending: true };
}

/** The selection after a new sample: kept while its process is listed, else none. */
export function keptSelection(selected: string | null, rows: readonly TaskManagerRow[]): string | null {
  return selected !== null && rows.some((row) => row.id === selected) ? selected : null;
}

/** The PID column: the pid on this Mac, `host:pid` on another. */
export function pidText(row: TaskManagerRow): string {
  return row.host === "local" ? String(row.pid) : row.id;
}

/** The selected row, when Kill Process may end it; else null. */
export function killableRow(rows: readonly TaskManagerRow[], selected: string | null): TaskManagerRow | null {
  const row = selected === null ? undefined : rows.find((candidate) => candidate.id === selected);
  return row && row.refusal === null ? row : null;
}

/** The row `step` rows from the selected one in `rows` (the shown order); the first or last when none. */
export function steppedSelection(
  rows: readonly TaskManagerRow[],
  selected: string | null,
  step: 1 | -1,
): string | null {
  if (rows.length === 0) return null;
  const index = selected === null ? -1 : rows.findIndex((row) => row.id === selected);
  if (index < 0) return (step > 0 ? rows[0] : rows[rows.length - 1]).id;
  return rows[Math.min(rows.length - 1, Math.max(0, index + step))].id;
}
