import { Database } from "bun:sqlite";

/**
 * The subset of Durable Object SQLite storage that Drizzle's durable-sqlite
 * driver and the stores use (`sql.exec` cursors and `transactionSync`), backed
 * by bun:sqlite so storage-level tests run deterministically without workerd.
 * The real-runtime suites in e2e/ exercise the same stores under workerd.
 */
export function sqliteStorage(): DurableObjectStorage {
  const db = new Database(":memory:");
  const cursor = (query: string, params: unknown[]) => {
    const statement = db.prepare(query);
    const values = (statement.values(...(params as never[])) ?? []) as unknown[][];
    const names = statement.columnNames;
    const objects = values.map(row => Object.fromEntries(names.map((name, index) => [name, row[index]])));
    const iterator = objects[Symbol.iterator]();
    return {
      columnNames: names,
      toArray: () => objects,
      next: () => iterator.next(),
      one: () => { if (objects.length !== 1) throw new Error("Expected exactly one row"); return objects[0]; },
      raw: () => ({ toArray: () => values, [Symbol.iterator]: () => values[Symbol.iterator]() }),
      [Symbol.iterator]: () => iterator,
    };
  };
  const storage = {
    sql: { exec: (query: string, ...params: unknown[]) => cursor(query, params) },
    transactionSync: <T>(action: () => T): T => db.transaction(action)(),
  };
  return storage as unknown as DurableObjectStorage;
}
