/**
 * One Durable Object per VM (named by the public VM id) holding that VM's paused-read replica in SQLite: the text of
 * the files under one root, read from the paused disk once, so a whole-tree search is one query instead of one API
 * read per file (cmuxterm-hq RFD 0144 piece 2). A new seed replaces the old one whole, in one transaction.
 */
import { DurableObject } from "cloudflare:workers";
import { matchLines, type ReplicaFile, type ReplicaMeta, type SearchMatch } from "./match.ts";

export class PausedReplicaObject extends DurableObject {
  private ready = false;

  private sql(): SqlStorage {
    const sql = this.ctx.storage.sql;
    if (!this.ready) {
      sql.exec("CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, text TEXT)");
      sql.exec("CREATE TABLE IF NOT EXISTS meta (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL)");
      this.ready = true;
    }
    return sql;
  }

  replace(meta: ReplicaMeta, files: ReadonlyArray<ReplicaFile>): void {
    const sql = this.sql();
    this.ctx.storage.transactionSync(() => {
      sql.exec("DELETE FROM files");
      for (const file of files) sql.exec("INSERT OR REPLACE INTO files (path, text) VALUES (?, ?)", file.path, file.text);
      sql.exec("INSERT OR REPLACE INTO meta (id, json) VALUES (1, ?)", JSON.stringify(meta));
    });
  }

  /** The stored meta as JSON (the store decodes it), or null before the first seed. */
  meta(): string | null {
    return this.sql().exec<{ json: string }>("SELECT json FROM meta WHERE id = 1").toArray()[0]?.json ?? null;
  }

  /** The search's answer as JSON, which the store decodes. */
  search(root: string, query: string, limit: number): string {
    const sql = this.sql();
    const prefix = root.endsWith("/") ? root : `${root}/`;
    const inRoot = "(path = ? OR substr(path, 1, ?) = ?)";
    const scanned = sql.exec<{ n: number }>(`SELECT count(*) AS n FROM files WHERE ${inRoot}`, root, prefix.length, prefix).one().n;
    const matches: SearchMatch[] = [];
    const rows = sql.exec<{ path: string; text: string }>(
      `SELECT path, text FROM files WHERE text IS NOT NULL AND ${inRoot} AND instr(text, ?) > 0 ORDER BY path`,
      root, prefix.length, prefix, query,
    );
    for (const row of rows) {
      matchLines(row.path, row.text, query, limit, matches);
      if (matches.length >= limit) break;
    }
    return JSON.stringify({ matches, scanned });
  }

  drop(): void {
    const sql = this.sql();
    this.ctx.storage.transactionSync(() => {
      sql.exec("DELETE FROM files");
      sql.exec("DELETE FROM meta");
    });
  }
}
