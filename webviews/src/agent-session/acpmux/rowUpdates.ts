// Snapshot metadata points to one producer, never a previous array or a snapshot chain.
// An open fence reads its indexed row and event revision without scanning transcript history.
import type { AcpmuxRow } from "./model";
import { LiveRowTable } from "../shared/liveRowTable";

const sources = new WeakMap<object, RowUpdates>();
let generation = 0;
export const rowUpdates = (rows: object) => sources.get(rows);

export class RowUpdates {
  readonly generation = ++generation;
  private orders = new LiveRowTable<AcpmuxRow, number>();

  constructor(readonly rowOf: (id: string) => AcpmuxRow | undefined) {}

  orderOf(row: AcpmuxRow) {
    return this.orders.get(row) ?? row.at;
  }
  note(row: AcpmuxRow, order: number) {
    this.orders.set(row, order);
  }
  /// Only the rows on hand are read (`rowOf`): past twice their count in writes, the orders of rows
  /// replaced since are dropped (liveRowTable.ts), so a long stream's table stays the chat's size.
  keepLive(size: number, live: () => Iterable<AcpmuxRow>) {
    this.orders = this.orders.compacted(size, live);
  }
  publish(rows: readonly AcpmuxRow[]) {
    sources.set(rows, this);
  }
}
