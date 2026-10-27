// Per-open derived views consume every published tool delta even when React skips snapshots.
// Metadata points to one producer, never a previous array or a snapshot chain.
import type { AcpmuxActivity, AcpmuxRow } from "./model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
export type RowUpdate = { id: string; version: number; order: number; tool: Tool; before?: Tool };
type Listener = (changes: Iterable<RowUpdate>) => void;
const sources = new WeakMap<object, RowUpdates>();
export const rowUpdates = (rows: object) => sources.get(rows);

export class RowUpdates {
  private pending = new Map<string, Map<string, RowUpdate>>();
  private listeners = new Set<Listener>();
  private orders = new WeakMap<AcpmuxRow, number>();

  orderOf(row: AcpmuxRow) {
    return this.orders.get(row) ?? row.at;
  }
  note(row: AcpmuxRow, order: number, previous?: AcpmuxRow, changedItem?: number) {
    this.orders.set(row, order);
    if (!this.listeners.size) return;
    const end = changedItem === undefined ? (row.items?.length ?? 0) : changedItem + 1;
    for (let index = changedItem ?? 0; index < end; index++) {
      const tool = row.items![index]!.tool;
      const before = previous?.items?.[index]?.tool;
      if (!tool || tool === before) continue;
      let changes = this.pending.get(row.id);
      if (!changes) this.pending.set(row.id, (changes = new Map()));
      const pending = changes.get(tool.id);
      changes.set(tool.id, {
        id: row.id,
        version: row.version,
        order,
        tool,
        before: pending ? pending.before : before?.id === tool.id ? before : undefined,
      });
    }
  }
  forget(id: string) {
    this.pending.delete(id);
  }
  clear() {
    this.pending.clear();
  }
  subscribe(listener: Listener) {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }
  publish(rows: readonly AcpmuxRow[]) {
    sources.set(rows, this);
    const changes = this.pending;
    this.pending = new Map(); // Flush even with no preview; idle producers retain no tool records.
    for (const listener of this.listeners) {
      try {
        for (const group of changes.values()) listener(group.values());
      } catch {
        this.listeners.delete(listener);
      } // A failed preview cannot break chat snapshots.
    }
  }
}
