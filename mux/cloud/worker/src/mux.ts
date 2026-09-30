import type { ID, Message, Participant } from "@mux/protocol";
import { DurableObject } from "cloudflare:workers";
import { conversation, type Env } from "./env.ts";

interface Pending {
  conversationId: ID;
  message: Message;
}

/**
 * One per mux. Incoming messages go to a durable inbox; an alarm drains it one
 * turn at a time, so a crash or deploy mid-turn retries instead of dropping.
 */
export class MuxDO extends DurableObject<Env> {
  private sql = this.ctx.storage.sql;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS inbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, json TEXT NOT NULL);
    `);
  }

  async ensure(id: ID, displayName: string): Promise<Participant> {
    this.sql.exec(
      "INSERT OR IGNORE INTO meta (key, value) VALUES ('participant', ?)",
      JSON.stringify({ kind: "mux", id, displayName } satisfies Participant),
    );
    return this.participant();
  }

  async receive(conversationId: ID, message: Message): Promise<void> {
    this.sql.exec(
      "INSERT INTO inbox (json) VALUES (?)",
      JSON.stringify({ conversationId, message } satisfies Pending),
    );
    if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now());
  }

  override async alarm(): Promise<void> {
    const row = this.sql
      .exec<{ seq: number; json: string }>("SELECT seq, json FROM inbox ORDER BY seq LIMIT 1")
      .toArray()[0];
    if (!row) return;
    const pending = JSON.parse(row.json) as Pending;
    await this.turn(pending);
    this.sql.exec("DELETE FROM inbox WHERE seq = ?", row.seq);
    if (this.sql.exec("SELECT 1 FROM inbox LIMIT 1").toArray().length > 0)
      await this.ctx.storage.setAlarm(Date.now());
  }

  private async turn({ conversationId, message }: Pending): Promise<void> {
    const me = this.participant();
    const room = conversation(this.env, conversationId);
    await room.setTyping(me.id, true);
    try {
      const text = message.parts.map((p) => (p.type === "text" ? p.text : "")).join(" ");
      await room.post(me.id, [{ type: "text", text: `(no brain yet) heard: ${text}` }]);
    } finally {
      await room.setTyping(me.id, false);
    }
  }

  private participant(): Participant {
    const row = this.sql
      .exec<{ value: string }>("SELECT value FROM meta WHERE key = 'participant'")
      .toArray()[0];
    if (!row) throw new Error("mux not initialized");
    return JSON.parse(row.value) as Participant;
  }
}
