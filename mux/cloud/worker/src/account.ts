import type { ConversationSummary, ID, Viewer } from "@mux/protocol";
import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env.ts";

/** One per human: profile, conversation list, default mux. */
export class AccountDO extends DurableObject<Env> {
  private sql = this.ctx.storage.sql;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, preview TEXT NOT NULL, last_at TEXT NOT NULL
      );
    `);
  }

  /** Records the viewer and returns the id of their default mux. */
  async signIn(viewer: Viewer): Promise<ID> {
    this.sql.exec(
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('viewer', ?)",
      JSON.stringify(viewer),
    );
    return `mux-${viewer.id}`;
  }

  async listConversations(): Promise<ConversationSummary[]> {
    return this.sql
      .exec<{ id: string; title: string; preview: string; last_at: string }>(
        "SELECT id, title, preview, last_at FROM conversations ORDER BY last_at DESC",
      )
      .toArray()
      .map((row) => ({ id: row.id, title: row.title, preview: row.preview, lastAt: row.last_at }));
  }

  async upsertConversation(summary: ConversationSummary): Promise<void> {
    this.sql.exec(
      "INSERT OR REPLACE INTO conversations (id, title, preview, last_at) VALUES (?, ?, ?, ?)",
      summary.id,
      summary.title,
      summary.preview,
      summary.lastAt,
    );
  }
}
