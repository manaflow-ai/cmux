import {
  conversationInput,
  DEFAULT_MODEL,
  instructions,
  responsesModel,
  runTurn,
  type ModelConfig,
} from "@mux/brain";
import type { ID, Message, Participant } from "@mux/protocol";
import { DurableObject } from "cloudflare:workers";
import { conversation, type Env } from "./env.ts";

/** Turn attempts before the mux reports the error in chat and moves on. */
const MAX_ATTEMPTS = 3;

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
      CREATE TABLE IF NOT EXISTS inbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, json TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0
      );
    `);
    // Inboxes created before attempts were counted.
    const columns = this.sql.exec<{ name: string }>("PRAGMA table_info(inbox)").toArray();
    if (!columns.some((c) => c.name === "attempts")) {
      this.sql.exec("ALTER TABLE inbox ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0");
    }
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
      .exec<{ seq: number; json: string; attempts: number }>(
        "SELECT seq, json, attempts FROM inbox ORDER BY seq LIMIT 1",
      )
      .toArray()[0];
    if (!row) return;
    const pending = JSON.parse(row.json) as Pending;
    this.sql.exec("UPDATE inbox SET attempts = attempts + 1 WHERE seq = ?", row.seq);
    try {
      await this.turn(pending);
    } catch (error) {
      if (row.attempts + 1 < MAX_ATTEMPTS) {
        await this.ctx.storage.setAlarm(Date.now() + 2_000 * 2 ** row.attempts);
        return;
      }
      const reason = error instanceof Error ? error.message : String(error);
      await conversation(this.env, pending.conversationId)
        .post(this.participant().id, [
          { type: "text", text: `I could not answer that: ${reason.slice(0, 300)}` },
        ])
        .catch(() => undefined);
    }
    this.sql.exec("DELETE FROM inbox WHERE seq = ?", row.seq);
    if (this.sql.exec("SELECT 1 FROM inbox LIMIT 1").toArray().length > 0)
      await this.ctx.storage.setAlarm(Date.now());
  }

  private async turn({ conversationId }: Pending): Promise<void> {
    const me = this.participant();
    const room = conversation(this.env, conversationId);
    await room.setTyping(me.id, true);
    try {
      const snapshot = await room.snapshot();
      const context = { muxId: me.id, conversation: snapshot };
      const result = await runTurn({
        model: responsesModel(this.modelConfig(me.id)),
        instructions: instructions(context),
        input: conversationInput(context),
      });
      if (result.text) await room.post(me.id, [{ type: "text", text: result.text }]);
    } finally {
      await room.setTyping(me.id, false);
    }
  }

  private modelConfig(muxId: ID): ModelConfig {
    const row = this.sql
      .exec<{ value: string }>("SELECT value FROM meta WHERE key = 'model'")
      .toArray()[0];
    const stored = row ? (JSON.parse(row.value) as Partial<ModelConfig>) : {};
    const apiKey = this.env.CODEROUTER_API_KEY;
    if (!apiKey) throw new Error("CODEROUTER_API_KEY is not set");
    return {
      ...DEFAULT_MODEL,
      baseUrl: this.env.CODEROUTER_BASE_URL ?? DEFAULT_MODEL.baseUrl,
      promptCacheKey: muxId,
      ...stored,
      apiKey,
    };
  }

  private participant(): Participant {
    const row = this.sql
      .exec<{ value: string }>("SELECT value FROM meta WHERE key = 'participant'")
      .toArray()[0];
    if (!row) throw new Error("mux not initialized");
    return JSON.parse(row.value) as Participant;
  }
}
