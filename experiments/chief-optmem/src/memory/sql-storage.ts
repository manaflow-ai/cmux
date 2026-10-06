import type { Entry, Knob, MemoryStorage } from "./storage.ts";

/**
 * The part of Durable Object SQLite this storage needs (`ctx.storage.sql.exec(...).toArray()`),
 * so tests can run it on node:sqlite.
 */
export type SqlExec = <T = Record<string, unknown>>(query: string, ...params: Array<unknown>) => Array<T>;

/** Rows read per query while scanning; a million-entry search never holds the log. */
const SCAN_PAGE = 4096;

/**
 * A memory in SQLite: `mem_entry` is the log (n = the entry id, dense),
 * `mem_node` the summaries, `mem_level` each level's dense prefix length,
 * `mem_knob` the overrides. Rows in `mem_node` at or past a level's prefix are
 * dead (forget only shortens the prefix) and are overwritten on rebuild.
 */
export class SqlMemoryStorage implements MemoryStorage {
  private count: number;

  constructor(private readonly sql: SqlExec) {
    sql(`CREATE TABLE IF NOT EXISTS mem_entry (n INTEGER PRIMARY KEY, date TEXT NOT NULL, text TEXT NOT NULL)`);
    sql(
      `CREATE TABLE IF NOT EXISTS mem_node (size INTEGER NOT NULL, k INTEGER NOT NULL, text TEXT NOT NULL, PRIMARY KEY (size, k))`,
    );
    sql(`CREATE TABLE IF NOT EXISTS mem_level (size INTEGER PRIMARY KEY, built INTEGER NOT NULL)`);
    sql(`CREATE TABLE IF NOT EXISTS mem_knob (name TEXT PRIMARY KEY, value INTEGER NOT NULL)`);
    this.count = this.readCount();
  }

  private readCount() {
    return Number(this.sql<{ t: number }>(`SELECT coalesce(max(n) + 1, 0) AS t FROM mem_entry`)[0]!.t);
  }

  /** Re-reads cached state after a rolled-back transaction. */
  refresh() {
    this.count = this.readCount();
  }

  length() {
    return this.count;
  }

  entries(lo: number, hi: number): Array<Entry> {
    return this.sql<{ n: number; date: string; text: string }>(
      `SELECT n, date, text FROM mem_entry WHERE n >= ? AND n < ? ORDER BY n`,
      lo,
      hi,
    ).map((r) => ({ n: Number(r.n), date: r.date, text: r.text }));
  }

  *scan(): Iterable<Entry> {
    for (let lo = 0; lo < this.count; lo += SCAN_PAGE) yield* this.entries(lo, Math.min(lo + SCAN_PAGE, this.count));
  }

  append(items: ReadonlyArray<{ readonly date: string; readonly text: string }>) {
    const base = this.count;
    items.forEach((e, i) =>
      this.sql(`INSERT INTO mem_entry (n, date, text) VALUES (?, ?, ?)`, base + i, e.date, e.text),
    );
    this.count += items.length;
    return base;
  }

  built(size: number) {
    const row = this.sql<{ built: number }>(`SELECT built FROM mem_level WHERE size = ?`, size)[0];
    return row ? Number(row.built) : 0;
  }

  node(size: number, k: number) {
    return this.sql<{ text: string }>(`SELECT text FROM mem_node WHERE size = ? AND k = ?`, size, k)[0]?.text;
  }

  putNode(size: number, k: number, text: string) {
    const built = this.built(size);
    if (k !== built) throw new Error(`level ${size} has ${built} blocks, cannot write block ${k}`);
    this.sql(
      `INSERT INTO mem_node (size, k, text) VALUES (?, ?, ?) ON CONFLICT (size, k) DO UPDATE SET text = excluded.text`,
      size,
      k,
      text,
    );
    this.sql(
      `INSERT INTO mem_level (size, built) VALUES (?, ?) ON CONFLICT (size) DO UPDATE SET built = excluded.built`,
      size,
      k + 1,
    );
  }

  truncate(size: number, k: number) {
    this.sql(`UPDATE mem_level SET built = ? WHERE size = ? AND built > ?`, k, size, k);
  }

  overrides() {
    const out: Partial<Record<Knob, number>> = {};
    for (const r of this.sql<{ name: Knob; value: number }>(`SELECT name, value FROM mem_knob`))
      out[r.name] = Number(r.value);
    return out;
  }

  setOverrides(over: Partial<Record<Knob, number>>) {
    this.sql(`DELETE FROM mem_knob`);
    for (const [name, value] of Object.entries(over))
      this.sql(`INSERT INTO mem_knob (name, value) VALUES (?, ?)`, name, value);
  }
}
