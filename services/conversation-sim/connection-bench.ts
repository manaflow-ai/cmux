// Bounded connection duress benchmark for conversation-sim.
// It owns a simulator, forces deterministic drops, reconnects with the
// protocol replay cursor, and writes one JSON object per run.

import { join } from "node:path";

export type ConnectionBenchOptions = {
  drops: number;
  reconnectGoalMs: number;
  latencyScale: number;
  failRate: number;
  duplicateRate: number;
  historyFailRate: number;
};

export type ConnectionBenchSummary = {
  schema: "cmux.connection-bench.v1";
  dropsRequested: number;
  dropsObserved: number;
  reconnects: number;
  reconnectLatencyMs: number[];
  reconnectLatencyP50Ms: number;
  reconnectLatencyP95Ms: number;
  reconnectLatencyMaxMs: number;
  laggedReconnects: number;
  replayedEvents: number;
  duplicateEvents: number;
  idempotentSend: boolean;
  goals: {
    reconnectWithinGoal: { targetMs: number; actualP95Ms: number; pass: boolean };
    replayWithoutLag: { laggedReconnects: number; pass: boolean };
    idempotentSend: { pass: boolean };
  };
  pass: boolean;
};

type Frame = { id?: number; method?: string; params?: any; result?: any; error?: { message: string } };
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export function percentile(values: number[], fraction: number): number {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(fraction * sorted.length) - 1)] ?? 0;
}

export function summarize(
  options: Pick<ConnectionBenchOptions, "drops" | "reconnectGoalMs">,
  observed: {
    dropsObserved: number;
    reconnectLatencyMs: number[];
    laggedReconnects: number;
    replayedEvents: number;
    duplicateEvents: number;
    idempotentSend: boolean;
  },
): ConnectionBenchSummary {
  const p50 = percentile(observed.reconnectLatencyMs, 0.5);
  const p95 = percentile(observed.reconnectLatencyMs, 0.95);
  const max = Math.max(0, ...observed.reconnectLatencyMs);
  const goals = {
    reconnectWithinGoal: { targetMs: options.reconnectGoalMs, actualP95Ms: p95, pass: p95 <= options.reconnectGoalMs },
    replayWithoutLag: { laggedReconnects: observed.laggedReconnects, pass: observed.laggedReconnects === 0 },
    idempotentSend: { pass: observed.idempotentSend },
  };
  return {
    schema: "cmux.connection-bench.v1",
    dropsRequested: options.drops,
    dropsObserved: observed.dropsObserved,
    reconnects: observed.reconnectLatencyMs.length,
    reconnectLatencyMs: observed.reconnectLatencyMs,
    reconnectLatencyP50Ms: p50,
    reconnectLatencyP95Ms: p95,
    reconnectLatencyMaxMs: max,
    laggedReconnects: observed.laggedReconnects,
    replayedEvents: observed.replayedEvents,
    duplicateEvents: observed.duplicateEvents,
    idempotentSend: observed.idempotentSend,
    goals,
    pass:
      observed.dropsObserved === options.drops &&
      observed.reconnectLatencyMs.length === options.drops &&
      goals.reconnectWithinGoal.pass &&
      goals.replayWithoutLag.pass &&
      goals.idempotentSend.pass,
  };
}

class BenchClient {
  private ws!: WebSocket;
  private nextId = 0;
  private pending = new Map<number, (frame: Frame) => void>();
  private closedResolve: (() => void) | null = null;
  private readonly closedPromise = new Promise<void>((resolve) => { this.closedResolve = resolve; });
  private replayResolve: (() => void) | null = null;
  private replayPromise: Promise<void> | null = null;
  private replaying = false;
  lastEventSeq = 0;
  replayedEvents = 0;
  duplicateEvents = 0;
  lagged = false;

  constructor(private readonly base: string, private readonly clientId: string) {}

  async connect(): Promise<any> {
    this.ws = new WebSocket(`${this.base.replace(/^http/, "ws")}/ws?conversation=group`);
    this.ws.onmessage = (event) => this.receive(JSON.parse(String(event.data)) as Frame);
    this.ws.onclose = () => {
      for (const resolve of this.pending.values()) resolve({ error: { message: "socket closed" } });
      this.pending.clear();
      this.closedResolve?.();
      this.closedResolve = null;
    };
    await new Promise<void>((resolve, reject) => {
      this.ws.onopen = () => resolve();
      this.ws.onerror = () => reject(new Error("connection benchmark WebSocket error"));
    });
    const resumeAfterEventSeq = this.lastEventSeq || undefined;
    if (resumeAfterEventSeq !== undefined) {
      this.replaying = true;
      this.replayPromise = new Promise((resolve) => { this.replayResolve = resolve; });
    }
    const hello = await this.call("hello", { clientId: this.clientId, resumeAfterEventSeq });
    if (hello.error) throw new Error(`hello failed: ${hello.error.message}`);
    this.lagged = hello.result?.lagged === true;
    if (this.replayPromise) {
      await Promise.race([this.replayPromise, sleep(5_000).then(() => { throw new Error("replayDone timeout"); })]);
      this.replayPromise = null;
    }
    return hello.result;
  }

  private receive(frame: Frame) {
    if (frame.id !== undefined) {
      this.pending.get(frame.id)?.(frame);
      this.pending.delete(frame.id);
      return;
    }
    if (frame.method === "event") {
      const eventSeq = Number(frame.params?.eventSeq ?? 0);
      if (eventSeq <= this.lastEventSeq) this.duplicateEvents++;
      else {
        this.lastEventSeq = eventSeq;
        if (this.replaying) this.replayedEvents++;
      }
    }
    if (frame.method === "replayDone") {
      this.replaying = false;
      this.replayResolve?.();
      this.replayResolve = null;
    }
  }

  call(method: string, params: unknown): Promise<Frame> {
    const id = ++this.nextId;
    return new Promise((resolve) => {
      this.pending.set(id, resolve);
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  async waitClosed() {
    await Promise.race([this.closedPromise, sleep(5_000).then(() => { throw new Error("disconnect timeout"); })]);
  }

  close() { this.ws.close(); }
}

async function post(base: string, path: string, body?: unknown) {
  const response = await fetch(base + path, {
    method: "POST",
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${path} -> ${response.status} ${await response.text()}`);
  return response.json();
}

async function waitForHealth(base: string) {
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      if ((await fetch(base + "/healthz")).ok) return;
    } catch {}
    await sleep(100);
  }
  throw new Error("conversation-sim did not become healthy");
}

function numberFlag(args: Map<string, string>, name: string, fallback: number): number {
  const value = Number(args.get(name));
  return Number.isFinite(value) ? value : fallback;
}

export async function runConnectionBench(options: ConnectionBenchOptions): Promise<ConnectionBenchSummary> {
  const port = 20_000 + Math.floor(Math.random() * 20_000);
  const base = `http://127.0.0.1:${port}`;
  const proc = Bun.spawn(["bun", "run", join(import.meta.dir, "server.ts")], {
    env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", LOG: "", BOT_INTERVAL_SCALE: "10000" },
    stdout: "ignore",
    stderr: "inherit",
  });
  let client = new BenchClient(base, `connection-bench-${process.pid}`);
  const reconnectLatencyMs: number[] = [];
  let dropsObserved = 0;
  let laggedReconnects = 0;
  let replayedEvents = 0;
  let duplicateEvents = 0;
  let idempotentSend = false;
  try {
    await waitForHealth(base);
    await post(base, "/admin/knobs", {
      latencyScale: options.latencyScale,
      failRate: options.failRate,
      historyFailRate: options.historyFailRate,
      duplicateRate: options.duplicateRate,
      disconnectEverySeconds: 0,
      botIntervalScale: 10000,
    });
    await client.connect();
    const clientMessageId = `connection-bench-${crypto.randomUUID()}`;
    const first = await client.call("send", { clientMessageId, text: "connection benchmark" });
    const second = await client.call("send", { clientMessageId, text: "connection benchmark retry" });
    idempotentSend = first.result?.message?.id === second.result?.message?.id;
    for (let i = 0; i < options.drops; i++) {
      const started = performance.now();
      const lastEventSeq = client.lastEventSeq;
      await post(base, "/admin/disconnect");
      await client.waitClosed();
      dropsObserved++;
      await post(base, "/admin/burst?conversation=group&count=1&intervalMs=0");
      const reconnect = new BenchClient(base, `connection-bench-${process.pid}`);
      reconnect.lastEventSeq = lastEventSeq;
      await reconnect.connect();
      reconnectLatencyMs.push(Math.round((performance.now() - started) * 100) / 100);
      if (reconnect.lagged) laggedReconnects++;
      replayedEvents += reconnect.replayedEvents;
      duplicateEvents += reconnect.duplicateEvents;
      client = reconnect;
    }
  } finally {
    try { client.close(); } catch {}
    proc.kill();
  }
  return summarize(options, { dropsObserved, reconnectLatencyMs, laggedReconnects, replayedEvents, duplicateEvents, idempotentSend });
}

function parseArgs(argv: string[]) {
  const values = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg?.startsWith("--")) continue;
    const [key, inline] = arg.slice(2).split("=", 2);
    values.set(key, inline ?? argv[++i] ?? "");
  }
  return values;
}

if (import.meta.main) {
  const args = parseArgs(process.argv.slice(2));
  const options: ConnectionBenchOptions = {
    drops: Math.max(1, Math.floor(numberFlag(args, "drops", 3))),
    reconnectGoalMs: Math.max(1, numberFlag(args, "reconnect-goal-ms", 3_000)),
    latencyScale: Math.max(0, numberFlag(args, "latency-scale", 0.02)),
    failRate: Math.min(1, Math.max(0, numberFlag(args, "fail-rate", 0))),
    duplicateRate: Math.min(1, Math.max(0, numberFlag(args, "duplicate-rate", 0))),
    historyFailRate: Math.min(1, Math.max(0, numberFlag(args, "history-fail-rate", 0))),
  };
  const result = await runConnectionBench(options);
  const line = JSON.stringify(result);
  if (args.get("output")) await Bun.write(args.get("output")!, line + "\n");
  console.log(line);
  process.exitCode = result.pass ? 0 : 1;
}
