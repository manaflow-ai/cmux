import { key, type MemoryStore, type Range } from "@mux/brain";

/** A mux's memory in its Durable Object's SQLite. Step 5 replaces it with a git repo on a VM. */
export class SqliteMemoryStore implements MemoryStore {
  private sql: SqlStorage;

  constructor(sql: SqlStorage) {
    this.sql = sql;
    sql.exec(`
      CREATE TABLE IF NOT EXISTS mem_lines (idx INTEGER PRIMARY KEY, line TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS mem_nodes (key TEXT PRIMARY KEY, summary TEXT NOT NULL);
    `);
  }

  async length() {
    return this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM mem_lines").one().n;
  }

  async append(lines: string[]) {
    let n = await this.length();
    for (const line of lines)
      this.sql.exec("INSERT INTO mem_lines (idx, line) VALUES (?, ?)", n++, line);
    return n;
  }

  async read(start: number, end: number) {
    return this.sql
      .exec<{ line: string }>(
        "SELECT line FROM mem_lines WHERE idx >= ? AND idx < ? ORDER BY idx",
        start,
        end,
      )
      .toArray()
      .map((r) => r.line);
  }

  async recall(pattern: string, limit: number) {
    const re = new RegExp(pattern, "i");
    const hits: { index: number; line: string }[] = [];
    for (const row of this.sql.exec<{ idx: number; line: string }>(
      "SELECT idx, line FROM mem_lines ORDER BY idx DESC",
    )) {
      if (re.test(row.line)) hits.push({ index: row.idx, line: row.line });
      if (hits.length >= limit) break;
    }
    return hits;
  }

  async getNodes(ranges: Range[]) {
    const found = new Map<string, string>();
    for (const r of ranges) {
      const row = this.sql
        .exec<{ summary: string }>("SELECT summary FROM mem_nodes WHERE key = ?", key(r))
        .toArray()[0];
      if (row) found.set(key(r), row.summary);
    }
    return found;
  }

  async putNode(range: Range, summary: string) {
    this.sql.exec(
      "INSERT OR REPLACE INTO mem_nodes (key, summary) VALUES (?, ?)",
      key(range),
      summary,
    );
  }

  async deleteNode(range: Range) {
    this.sql.exec("DELETE FROM mem_nodes WHERE key = ?", key(range));
  }
}
