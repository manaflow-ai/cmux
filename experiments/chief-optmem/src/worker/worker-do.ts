import { DurableObject } from "cloudflare:workers";
import { Type } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { createRegistry, Harness, type ToolRegistration } from "@earendil-works/pi-durable";
import { PiHarness } from "agents/harness/pi";
import { Lifecycle } from "agents/lifecycle";
import { createAI } from "agents/models/pi-ai";
import type { Env } from "./env.ts";

const WORKER_SYSTEM = `You are a worker agent started by Chief, a manager agent. Do the task in the prompt with
your tools and answer with the result: what you found or did, concrete and complete, in plain text.
Your final answer is reported back to Chief as is. Chief has no other view of your work.`;

const FetchArgs = Type.Object({ url: Type.String({ description: "An https URL to read." }) });

/** Characters of a fetched page the worker sees. */
const FETCH_LIMIT = 20_000;

const fetchUrl: ToolRegistration<typeof FetchArgs> = {
  name: "fetch_url",
  description: "Read a web page or API response (GET). Returns the body as text, cut to 20,000 characters.",
  parameters: FetchArgs,
  replay: "safe",
  async execute({ url }) {
    let target: URL;
    try {
      target = new URL(url);
    } catch {
      return { content: [{ type: "text", text: `Not a URL: ${url}` }] };
    }
    if (target.protocol !== "https:") return { content: [{ type: "text", text: "Only https URLs are allowed." }] };
    const response = await fetch(target, { headers: { "user-agent": "cmux-chief-worker/0" }, redirect: "follow" });
    const body = (await response.text()).slice(0, FETCH_LIMIT);
    return { content: [{ type: "text", text: `HTTP ${response.status}\n\n${body}` }] };
  },
};

/**
 * One worker of one chief (phase 1 of plans/cmux-next/chief.md section 5):
 * a pi session with read-only web tools. Each prompt runs as a follow-up in
 * its root session (the worker keeps its own history; it is not the chief);
 * its final answer goes back to the chief as a worker event.
 */
export class WorkerDO extends DurableObject<Env> {
  readonly ai = createAI({ binding: this.env.AI });
  readonly registry = createRegistry();
  readonly harness = new PiHarness({
    harness: ({ storage, context }) => {
      this.registry.install({
        name: "worker",
        sections: [{ key: "worker", render: () => WORKER_SYSTEM, tag: false }],
        tools: [fetchUrl],
      });
      const models = createModels();
      models.setProvider(this.ai.provider);
      return Harness.open(
        storage,
        { models, registry: this.registry, settings: { retry: { enabled: true, maxRetries: 5, baseDelayMs: 1000 } } },
        context,
      );
    },
    defaults: { model: this.ai(this.env.WORKER_MODEL), thinkingLevel: "low" },
  });
  readonly lifecycle = Lifecycle.install(this).use(this.harness);
  /** Operations this isolate is already waiting on. */
  private readonly following = new Set<string>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS worker_op (id TEXT PRIMARY KEY, chief TEXT NOT NULL, name TEXT NOT NULL, reported INTEGER NOT NULL DEFAULT 0)`,
    );
  }

  /** Reports every prompt that settled while the object was down. */
  async onStart(): Promise<void> {
    for (const r of this.ctx.storage.sql
      .exec<Record<string, SqlStorageValue>>(`SELECT id, chief, name FROM worker_op WHERE reported = 0`)
      .toArray()) {
      this.follow(String(r.id), String(r.chief), String(r.name));
    }
  }

  /** Runs `prompt` (idempotent by `operationId`) and reports its answer to the chief when it settles. */
  async start(chief: string, name: string, prompt: string, operationId: string): Promise<void> {
    await this.lifecycle.start();
    // Submit first: the submit starts the object, and its onStart must not follow an op pi has not seen.
    await this.harness.submit(prompt, { operationId });
    this.ctx.storage.sql.exec(
      `INSERT INTO worker_op (id, chief, name) VALUES (?, ?, ?) ON CONFLICT (id) DO NOTHING`,
      operationId,
      chief,
      name,
    );
    this.follow(operationId, chief, name);
  }

  private follow(operationId: string, chief: string, name: string): void {
    if (this.following.has(operationId)) return;
    this.following.add(operationId);
    const report = (async () => {
      const result = await this.harness.wait(operationId);
      const text =
        result.status === "done" ? (result.text ?? "") : `I could not finish: ${result.reason ?? "unanswered"}`;
      const stub = this.env.CHIEF_DO.get(this.env.CHIEF_DO.idFromName(chief));
      await stub.workerReport(chief, `report:${operationId}`, name, text || "(empty answer)");
      this.ctx.storage.sql.exec(`UPDATE worker_op SET reported = 1 WHERE id = ?`, operationId);
    })();
    this.ctx.waitUntil(report.catch((e) => console.error("worker report failed", e)));
  }
}
