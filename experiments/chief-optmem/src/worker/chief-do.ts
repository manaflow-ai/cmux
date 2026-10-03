import { DurableObject } from "cloudflare:workers";
import { Type } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { createRegistry, Harness, type ToolRegistration } from "@earendil-works/pi-durable";
import { PiHarness } from "agents/harness/pi";
import { Lifecycle } from "agents/lifecycle";
import { createAI } from "agents/models/pi-ai";
import {
  CHIEF_SYSTEM,
  type ChiefEvent,
  type MemoryPort,
  type ModelPort,
  type ModelReply,
  type ModelRequest,
  runTurn,
  type SpawnCall,
} from "../chief/turn.ts";
import type { Env } from "./env.ts";

/** One line of the conversation the UI shows. The model never reads this table. */
export interface ChiefMessage {
  readonly seq: number;
  readonly id: string;
  readonly kind: "human" | "chief" | "worker" | "error";
  readonly author: string;
  readonly text: string;
  readonly at: number;
}

const SpawnArgs = Type.Object({
  name: Type.String({
    description: "Short worker name, letters, digits and dashes. Reuse a name to steer that worker.",
  }),
  prompt: Type.String({ description: "Everything the worker needs to do the task; it does not share your memory." }),
});

const NAME = /^[a-z0-9][a-z0-9-]{0,39}$/;

/** Words of a model reply, from pi-ai's content parts. */
const textOf = (content: ReadonlyArray<{ type: string; text?: string }>) =>
  content
    .filter((p) => p.type === "text")
    .map((p) => p.text ?? "")
    .join("");

/**
 * One chief (plans/cmux-next/chief.md section 5). Events queue in
 * `chief_event`; one drain runs turns in order. Each turn resets pi's root
 * session and prompts it with only the memory cover and the new events, so
 * pi's transcript never reaches the model beyond the turn's own tool round.
 */
export class ChiefDO extends DurableObject<Env> {
  readonly ai = createAI({ binding: this.env.AI });
  readonly registry = createRegistry();
  /** Spawns made by the running turn's model call. */
  private spawns: Array<SpawnCall> = [];
  private turnId = "";
  private draining: Promise<void> | undefined;
  private readonly waiters = new Set<() => void>();

  readonly harness = new PiHarness({
    harness: ({ storage, context }) => {
      const spawn: ToolRegistration<typeof SpawnArgs> = {
        name: "spawn",
        description: "Start a worker agent with a task, or send a new prompt to a worker you started (same name).",
        parameters: SpawnArgs,
        // Starting a worker is keyed by the turn and the name, so a rerun starts it once.
        replay: "safe",
        execute: async ({ name, prompt }) => {
          const clean = name.toLowerCase();
          if (!NAME.test(clean))
            return { content: [{ type: "text", text: `Invalid name ${name}: use letters, digits and dashes.` }] };
          this.spawns.push({ name: clean, prompt });
          await this.worker(clean).start(this.chiefId(), clean, prompt, `spawn:${this.turnId}:${clean}`);
          return { content: [{ type: "text", text: `Worker ${clean} started. Its report arrives as a new event.` }] };
        },
      };
      this.registry.install({
        name: "chief",
        sections: [{ key: "chief", render: () => CHIEF_SYSTEM, tag: false }],
        tools: [spawn],
      });
      const models = createModels();
      models.setProvider(this.ai.provider);
      return Harness.open(
        storage,
        {
          models,
          registry: this.registry,
          settings: { retry: { enabled: true, maxRetries: 5, baseDelayMs: 1000 } },
          onReport: (error) => console.warn("pi report", error),
        },
        context,
      );
    },
    defaults: { model: this.ai(this.env.CHIEF_MODEL), thinkingLevel: "low" },
  });

  readonly lifecycle = Lifecycle.install(this).use(this.harness);

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql = ctx.storage.sql;
    sql.exec(`CREATE TABLE IF NOT EXISTS chief_meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)`);
    sql.exec(
      `CREATE TABLE IF NOT EXISTS chief_message (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, author TEXT NOT NULL, text TEXT NOT NULL, at INTEGER NOT NULL)`,
    );
    sql.exec(
      `CREATE TABLE IF NOT EXISTS chief_event (n INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, author TEXT NOT NULL, text TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)`,
    );
    sql.exec(`CREATE TABLE IF NOT EXISTS chief_turn (id TEXT PRIMARY KEY, submitted INTEGER NOT NULL DEFAULT 0)`);
  }

  /**
   * Host startup: finish events that were queued when the object stopped.
   * Native RPC does not start the lifecycle, so every public method awaits `lifecycle.start()`.
   */
  async onStart(): Promise<void> {
    console.log("chief onStart");
    this.kick();
  }

  // ---------------------------------------------------------------- API

  /** A person's message. Idempotent by its client id. */
  async send(chief: string, id: string, author: string, text: string): Promise<ChiefMessage> {
    await this.lifecycle.start();
    this.bind(chief);
    const message = this.record(id, "human", author, text);
    this.kick();
    return message;
  }

  /** A worker's report (its final answer for one prompt). Idempotent by the operation id. */
  async workerReport(chief: string, id: string, name: string, text: string): Promise<void> {
    await this.lifecycle.start();
    this.bind(chief);
    this.record(id, "worker", name, text);
    this.kick();
  }

  messages(after: number, limit = 200): Array<ChiefMessage> {
    return this.ctx.storage.sql
      .exec<Record<string, SqlStorageValue>>(
        `SELECT seq, id, kind, author, text, at FROM chief_message WHERE seq > ? ORDER BY seq LIMIT ?`,
        after,
        Math.min(Math.max(limit, 1), 1000),
      )
      .toArray()
      .map((r) => ({
        seq: Number(r.seq),
        id: String(r.id),
        kind: r.kind as ChiefMessage["kind"],
        author: String(r.author),
        text: String(r.text),
        at: Number(r.at),
      }));
  }

  /** The newest `tail` messages, or up to `limit` before `before`; ascending either way. */
  async page(options: { tail?: number; before?: number; limit?: number }): Promise<Array<ChiefMessage>> {
    await this.lifecycle.start();
    const limit = Math.min(Math.max(options.tail ?? options.limit ?? 60, 1), 1000);
    const before = options.before ?? Number.MAX_SAFE_INTEGER;
    return this.ctx.storage.sql
      .exec<Record<string, SqlStorageValue>>(
        `SELECT seq, id, kind, author, text, at FROM chief_message WHERE seq < ? ORDER BY seq DESC LIMIT ?`,
        before,
        limit,
      )
      .toArray()
      .reverse()
      .map((r) => ({
        seq: Number(r.seq),
        id: String(r.id),
        kind: r.kind as ChiefMessage["kind"],
        author: String(r.author),
        text: String(r.text),
        at: Number(r.at),
      }));
  }

  /** Messages after `after`, waiting up to `waitMs` for the first one (long poll). */
  async poll(after: number, waitMs: number): Promise<Array<ChiefMessage>> {
    await this.lifecycle.start();
    const now = this.messages(after);
    if (now.length > 0 || waitMs <= 0) return now;
    await new Promise<void>((resolve) => {
      const done = () => {
        clearTimeout(timer);
        this.waiters.delete(done);
        resolve();
      };
      const timer = setTimeout(done, Math.min(waitMs, 30_000));
      this.waiters.add(done);
    });
    return this.messages(after);
  }

  // ---------------------------------------------------------------- turns

  private chiefId(): string {
    const id = this.ctx.storage.sql
      .exec<{ value: string }>(`SELECT value FROM chief_meta WHERE name = 'id'`)
      .toArray()[0]?.value;
    if (!id) throw new Error("chief is not bound to an id yet");
    return id;
  }

  private bind(chief: string): void {
    this.ctx.storage.sql.exec(
      `INSERT INTO chief_meta (name, value) VALUES ('id', ?) ON CONFLICT (name) DO NOTHING`,
      chief,
    );
  }

  private record(id: string, kind: ChiefMessage["kind"], author: string, text: string): ChiefMessage {
    const sql = this.ctx.storage.sql;
    const at = Date.now();
    this.ctx.storage.transactionSync(() => {
      // Check first: a conflicting INSERT still advances AUTOINCREMENT, and clients need dense seqs
      // (the Home mirror reads a jump as a gap).
      if (sql.exec(`SELECT 1 FROM chief_message WHERE id = ?`, id).toArray().length > 0) return;
      sql.exec(
        `INSERT INTO chief_message (id, kind, author, text, at) VALUES (?, ?, ?, ?, ?)`,
        id,
        kind,
        author,
        text,
        at,
      );
      if (kind === "human" || kind === "worker") {
        sql.exec(
          `INSERT INTO chief_event (id, kind, author, text) VALUES (?, ?, ?, ?) ON CONFLICT (id) DO NOTHING`,
          id,
          kind,
          author,
          text,
        );
      }
    });
    for (const wake of this.waiters) wake();
    const row = sql.exec<Record<string, SqlStorageValue>>(`SELECT seq FROM chief_message WHERE id = ?`, id).one();
    return { seq: Number(row.seq), id, kind, author, text, at };
  }

  /** Starts the drain unless one runs. The object stays up while pi or the request holds it. */
  private kick(): void {
    if (this.draining) return;
    this.draining = this.drain().finally(() => {
      this.draining = undefined;
    });
    this.ctx.waitUntil(this.draining);
  }

  private async drain(): Promise<void> {
    const sql = this.ctx.storage.sql;
    for (;;) {
      const rows = sql
        .exec<Record<string, SqlStorageValue>>(
          `SELECT id, kind, author, text FROM chief_event WHERE done = 0 ORDER BY n LIMIT 20`,
        )
        .toArray();
      if (rows.length === 0) return;
      const events: Array<ChiefEvent> = rows.map((r) => ({
        id: String(r.id),
        kind: r.kind === "worker" ? "worker" : "human",
        from: String(r.author),
        text: String(r.text),
      }));
      const turnId = events[0]!.id;
      console.log("chief turn start", turnId, events.length);
      try {
        const result = await runTurn(turnId, events, this.memory(), this.model(turnId));
        if (result.reply.trim()) this.record(`reply:${turnId}`, "chief", "Chief", result.reply.trim());
      } catch (e) {
        console.error("chief turn failed", e);
        this.record(`error:${turnId}`, "error", "Chief", `This turn failed: ${(e as Error).message}`);
      }
      const ids = events.map((e) => e.id);
      sql.exec(`UPDATE chief_event SET done = 1 WHERE id IN (${ids.map(() => "?").join(",")})`, ...ids);
    }
  }

  private memory(): MemoryPort {
    const stub = this.env.MEMORY_DO.get(this.env.MEMORY_DO.idFromName(`memory:${this.chiefId()}`));
    return {
      view: () => stub.view(),
      note: (texts, key) => stub.note(texts, key),
      nap: (block, text, key) => stub.nap(block, text, key),
    };
  }

  private worker(name: string) {
    return this.env.WORKER_DO.get(this.env.WORKER_DO.idFromName(`${this.chiefId()}/${name}`));
  }

  private model(turnId: string): ModelPort {
    return {
      complete: async (request: ModelRequest): Promise<ModelReply> => {
        if (!request.tools) {
          // A compression: one plain completion, no session, no tools.
          const reply = await this.ai.completeSimple(this.ai(this.env.CHIEF_MODEL), {
            systemPrompt: request.system,
            messages: [{ role: "user", content: request.user, timestamp: Date.now() }],
          });
          return { text: textOf(reply.content), spawns: [] };
        }
        console.log("chief turn model call", turnId);
        this.turnId = turnId;
        this.spawns = [];
        const sql = this.ctx.storage.sql;
        const submitted = sql
          .exec<{ submitted: number }>(`SELECT submitted FROM chief_turn WHERE id = ?`, turnId)
          .toArray()[0];
        const operationId = `turn:${turnId}`;
        if (!submitted?.submitted) {
          // A fresh context for every turn: the model sees only this prompt (and its own tool round).
          await this.harness.session().reset();
          sql.exec(
            `INSERT INTO chief_turn (id, submitted) VALUES (?, 1) ON CONFLICT (id) DO UPDATE SET submitted = 1`,
            turnId,
          );
          await this.harness.submit(request.user, { operationId });
        }
        console.log("chief turn waiting", operationId, submitted?.submitted ?? 0);
        const result = await this.harness.wait(operationId);
        console.log("chief turn settled", operationId, result.status, result.reason ?? "");
        if (result.status !== "done") throw new Error(`model did not answer: ${result.reason ?? "unanswered"}`);
        return { text: result.text ?? "", spawns: this.spawns };
      },
    };
  }
}
