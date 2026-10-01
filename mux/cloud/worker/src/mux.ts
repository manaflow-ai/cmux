import {
  compact,
  conversationInput,
  DEFAULT_MODEL,
  eventInput,
  formatRunResult,
  instructions,
  messageText,
  outputText,
  responsesModel,
  RUN_TOOL,
  runModule,
  runTurn,
  SUMMARY_INSTRUCTIONS,
  toLines,
  wake,
  zoom,
  type ModelConfig,
  type RunResult,
  type Summarize,
  type ToolCall,
} from "@mux/brain";
import type { Conversation, ID, LinkEvent, Message, Participant } from "@mux/protocol";
import { DurableObject } from "cloudflare:workers";
import { conversation, type Env } from "./env.ts";
import { SqliteMemoryStore } from "./memory-store.ts";
import type { MuxApi, MuxApiProps } from "./mux-api.ts";

/** Turn attempts before the mux reports the error in chat and moves on. */
const MAX_ATTEMPTS = 3;
const RUN_TIMEOUT_MS = 60_000;
/** Memory lines shown to the model each turn (about 8k tokens). */
const WAKE_BUDGET = 96;
/** Summary levels up to this one use the small model; higher, rarer levels use the main model. */
const SMALL_MODEL_MAX_LEVEL = 3;
const SMALL_MODEL = { model: "gpt-6-luna", reasoningEffort: "low" } as const;

/** One inbox item: a chat message or an agent event, for one conversation. */
type Pending = { conversationId: ID; message: Message } | { conversationId: ID; event: LinkEvent };

interface Identity {
  participant: Participant;
  ownerId: ID;
}

/**
 * One per mux. Incoming messages and agent events go to a durable inbox; an
 * alarm drains it one turn at a time, so a crash or deploy mid-turn retries
 * instead of dropping.
 */
export class MuxDO extends DurableObject<Env> {
  private sql = this.ctx.storage.sql;
  private memory: SqliteMemoryStore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.memory = new SqliteMemoryStore(this.sql);
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

  /** Creates the mux on first use. The owner's machines are the ones it can drive. */
  async ensure(id: ID, displayName: string, ownerId: ID): Promise<Participant> {
    const identity: Identity = { participant: { kind: "mux", id, displayName }, ownerId };
    this.sql.exec(
      "INSERT OR IGNORE INTO meta (key, value) VALUES ('identity', ?)",
      JSON.stringify(identity),
    );
    return this.identity().participant;
  }

  async receive(conversationId: ID, message: Message): Promise<void> {
    await this.enqueue({ conversationId, message });
  }

  async receiveEvent(conversationId: ID, event: LinkEvent): Promise<void> {
    await this.enqueue({ conversationId, event });
  }

  override async alarm(): Promise<void> {
    const row = this.sql
      .exec<{ seq: number; json: string; attempts: number }>(
        "SELECT seq, json, attempts FROM inbox ORDER BY seq LIMIT 1",
      )
      .toArray()[0];
    if (!row) {
      await this.compactStep();
      return;
    }
    const pending = JSON.parse(row.json) as Pending;
    this.sql.exec("UPDATE inbox SET attempts = attempts + 1 WHERE seq = ?", row.seq);
    const kind = "event" in pending ? `event ${pending.event.kind}` : "message";
    console.log(
      JSON.stringify({ at: "mux.turn.start", seq: row.seq, attempt: row.attempts + 1, kind }),
    );
    try {
      await this.turn(pending);
      console.log(JSON.stringify({ at: "mux.turn.end", seq: row.seq }));
    } catch (error) {
      console.log(JSON.stringify({ at: "mux.turn.error", seq: row.seq, error: String(error) }));
      if (row.attempts + 1 < MAX_ATTEMPTS) {
        await this.ctx.storage.setAlarm(Date.now() + 2_000 * 2 ** row.attempts);
        return;
      }
      const reason = error instanceof Error ? error.message : String(error);
      await conversation(this.env, pending.conversationId)
        .post(this.identity().participant.id, [
          { type: "text", text: `I could not answer that: ${reason.slice(0, 300)}` },
        ])
        .catch(() => undefined);
    }
    this.sql.exec("DELETE FROM inbox WHERE seq = ?", row.seq);
    const more = this.sql.exec("SELECT 1 FROM inbox LIMIT 1").toArray().length > 0;
    if (more || this.compactionDue()) await this.ctx.storage.setAlarm(Date.now());
  }

  // Memory, for the MuxApi entrypoint.

  async memoryRecall(pattern: string, limit: number) {
    return this.memory.recall(pattern, Math.min(Math.max(limit, 1), 200));
  }

  async memoryZoom(lo: number, hi: number) {
    return zoom(this.memory, { lo, hi });
  }

  async memoryNote(text: string) {
    const index = await this.memory.length();
    await this.memory.append(toLines(`${new Date().toISOString().slice(0, 16)} note: ${text}`));
    return { index };
  }

  /** One bounded compaction step off the critical path; re-arms itself while work remains. */
  private async compactStep(): Promise<void> {
    if (!this.compactionDue()) return;
    const { missing } = await wake(this.memory, WAKE_BUDGET);
    if (missing.length === 0) {
      this.sql.exec("DELETE FROM meta WHERE key = 'compact'");
      console.log(JSON.stringify({ at: "mux.compact.done" }));
      return;
    }
    try {
      const written = await compact(this.memory, missing, this.summarizer(), 8);
      console.log(JSON.stringify({ at: "mux.compact", written, missing: missing.length }));
      await this.ctx.storage.setAlarm(Date.now() + 500);
    } catch (error) {
      console.log(JSON.stringify({ at: "mux.compact.error", error: String(error) }));
      await this.ctx.storage.setAlarm(Date.now() + 30_000);
    }
  }

  private compactionDue(): boolean {
    return this.sql.exec("SELECT 1 FROM meta WHERE key = 'compact'").toArray().length > 0;
  }

  private summarizer(): Summarize {
    const main = this.modelConfig(this.identity().participant.id);
    return async ({ left, right, level }) => {
      const config = level <= SMALL_MODEL_MAX_LEVEL ? { ...main, ...SMALL_MODEL } : main;
      const { output } = await responsesModel(config)({
        instructions: SUMMARY_INSTRUCTIONS,
        input: [{ role: "user", content: `A: ${left}\nB: ${right}` }],
      });
      return outputText(output);
    };
  }

  /** Appends what this turn saw to memory. */
  private async remember(snapshot: Conversation, pending: Pending): Promise<void> {
    const stamp = new Date().toISOString().slice(0, 16);
    const where = `[${snapshot.title}]`;
    if ("message" in pending) {
      const sender = snapshot.participants.find(
        (p) => p.id === pending.message.senderId,
      )?.displayName;
      await this.memory.append(
        toLines(
          `${stamp} ${where} ${sender ?? pending.message.senderId}: ${messageText(pending.message)}`,
        ),
      );
    } else {
      const e = pending.event;
      const text =
        e.kind === "turn_end"
          ? `agent ${e.name} ${e.status}: ${e.reply}`
          : `agent ${e.name} asks permission: ${e.title}`;
      await this.memory.append(toLines(`${stamp} ${where} ${text}`));
    }
  }

  private async enqueue(pending: Pending): Promise<void> {
    this.sql.exec("INSERT INTO inbox (json) VALUES (?)", JSON.stringify(pending));
    if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now());
  }

  private async turn(pending: Pending): Promise<void> {
    const { participant: me, ownerId } = this.identity();
    const room = conversation(this.env, pending.conversationId);
    await room.setTyping(me.id, true);
    try {
      const snapshot = await room.snapshot();
      await this.remember(snapshot, pending);
      const memory = await wake(this.memory, WAKE_BUDGET);
      if (memory.missing.length > 0)
        this.sql.exec("INSERT OR IGNORE INTO meta (key, value) VALUES ('compact', '1')");
      const context = { muxId: me.id, conversation: snapshot, memory: memory.text };
      const result = await runTurn({
        model: responsesModel(this.modelConfig(me.id)),
        instructions: instructions(context),
        input: [
          ...conversationInput(context),
          ...("event" in pending ? [eventInput(pending.event)] : []),
        ],
        tools: [RUN_TOOL],
        runTool: (call) =>
          this.runTool(call, { muxId: me.id, ownerId, conversationId: pending.conversationId }),
      });
      if (result.text) {
        await room.post(me.id, [{ type: "text", text: result.text }]);
        const stamp = new Date().toISOString().slice(0, 16);
        await this.memory.append(toLines(`${stamp} [${snapshot.title}] me: ${result.text}`));
      }
    } finally {
      await room.setTyping(me.id, false);
    }
  }

  /** Runs model-written code in a Dynamic Worker whose only capability is the `mux` API. */
  private async runTool(call: ToolCall, props: MuxApiProps): Promise<string> {
    if (call.name !== RUN_TOOL.name) return `no tool named ${call.name}`;
    const { code } = JSON.parse(call.arguments) as { code: string };
    console.log(JSON.stringify({ at: "mux.run", code: code.slice(0, 500) }));
    const exports = this.ctx.exports as unknown as {
      MuxApi: (options: { props: MuxApiProps }) => MuxApi;
    };
    const sandbox = this.env.LOADER.load({
      compatibilityDate: "2026-09-30",
      mainModule: "run.js",
      modules: { "run.js": runModule(code) },
      env: { API: exports.MuxApi({ props }) },
      globalOutbound: null,
    });
    const entry = sandbox.getEntrypoint("Run") as unknown as { run(): Promise<RunResult> };
    const result = await Promise.race([
      entry.run(),
      new Promise<RunResult>((resolve) =>
        setTimeout(
          () =>
            resolve({ ok: false, error: `timed out after ${RUN_TIMEOUT_MS / 1000}s`, logs: [] }),
          RUN_TIMEOUT_MS,
        ),
      ),
    ]);
    console.log(
      JSON.stringify({ at: "mux.run.result", ok: result.ok, error: result.error?.slice(0, 300) }),
    );
    return formatRunResult(result);
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

  private identity(): Identity {
    const row = this.sql
      .exec<{ value: string }>("SELECT value FROM meta WHERE key = 'identity'")
      .toArray()[0];
    if (!row) throw new Error("mux not initialized");
    return JSON.parse(row.value) as Identity;
  }
}
