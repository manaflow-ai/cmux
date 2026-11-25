// Snapshot metadata points to one producer, never a previous array or a snapshot chain.
// An open fence reads its indexed row and event revision without scanning transcript history.
import type { AcpmuxRow } from "./model";

const sources = new WeakMap<object, RowUpdates>();
let generation = 0;
export const rowUpdates = (rows: object) => sources.get(rows);

export class RowUpdates {
  readonly generation = ++generation;
  private orders = new WeakMap<AcpmuxRow, number>();

  constructor(readonly rowOf: (id: string) => AcpmuxRow | undefined) {}

  orderOf(row: AcpmuxRow) {
    return this.orders.get(row) ?? row.at;
  }
  note(row: AcpmuxRow, order: number) {
    this.orders.set(row, order);
  }
  publish(rows: readonly AcpmuxRow[]) {
    sources.set(rows, this);
  }
}
