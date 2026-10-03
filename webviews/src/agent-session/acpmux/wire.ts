// What the agent pane sent to and received from acpmux, for the ACP
// inspector and log export: every JSON-RPC request, reply and notification
// on the pane's WebSocket, with timing, plus the socket's lifecycle
// (connects, closes, errors, reconnects). One log per page, kept across
// reconnects and fresh handshakes, so a drop and what led to it stay visible.
//
// Bounded: at most MAX_ENTRIES entries and MAX_TEXT_CHARS of message text
// (about 4 MB as UTF-16). Each message keeps at most MAX_PAYLOAD_CHARS of its
// text. The oldest entries go first. Nothing is written to disk unless
// someone exports the log.

export const MAX_ENTRIES = 2_000;
export const MAX_TEXT_CHARS = 2 * 1024 * 1024;
export const MAX_PAYLOAD_CHARS = 16 * 1024;

export type WireKind = "request" | "notification" | "response" | "error" | "invalid" | "lifecycle";

export type WireEntry = {
  /** Order within this page. */
  seq: number;
  /** Wall-clock milliseconds. */
  at: number;
  /** `out` to acpmux, `in` from it, `local` for socket lifecycle. */
  dir: "out" | "in" | "local";
  kind: WireKind;
  method?: string;
  id?: number;
  /** Replies and errors: time since the request went out. */
  latencyMs?: number;
  /** Length of the message text, in UTF-16 code units. */
  size?: number;
  /** The message text, cut to MAX_PAYLOAD_CHARS. */
  text?: string;
  truncated?: boolean;
  /** Lifecycle events: what happened, for example `close` or `reconnect scheduled`. */
  event?: string;
  detail?: Record<string, unknown>;
};

export type WireStats = {
  entries: number;
  dropped: number;
  requests: number;
  errors: number;
  inFlight: number;
  connects: number;
  closes: number;
  reconnects: number;
  lastError?: string;
  latencyP50Ms?: number;
  latencyMaxMs?: number;
};

type Pending = { method: string; startedAt: number };

type Listener = () => void;

function percentile(sorted: number[], p: number): number | undefined {
  if (sorted.length === 0) return undefined;
  return sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))];
}

/** Removes the `token` query item from a URL, so a log never holds the daemon token. */
export function redactEndpoint(endpoint: string): string {
  try {
    const url = new URL(endpoint);
    url.searchParams.delete("token");
    return url.toString();
  } catch {
    return "(invalid endpoint)";
  }
}

export class AcpWireLog {
  private log: WireEntry[] = [];
  private bytes = 0; // characters of text held
  private nextSeq = 1;
  private droppedCount = 0;
  private pending = new Map<number, Pending>();
  private latencies: number[] = [];
  private counters = { requests: 0, errors: 0, connects: 0, closes: 0, reconnects: 0 };
  private lastError?: string;
  private listeners = new Set<Listener>();
  private readonly now: () => number;
  private readonly clock: () => number;

  /** `now` is wall-clock time for entries; `clock` is a monotonic clock for latency. */
  constructor(now: () => number = Date.now, clock: () => number = () => performance.now()) {
    this.now = now;
    this.clock = clock;
  }

  /** A request or notification the pane sent. */
  sent(text: string, method: string, id?: number): void {
    if (id !== undefined) {
      this.counters.requests += 1;
      this.pending.set(id, { method, startedAt: this.clock() });
    }
    this.push({ dir: "out", kind: id === undefined ? "notification" : "request", method, id, ...this.body(text) });
  }

  /** A message acpmux sent. */
  received(text: string): void {
    let message: any;
    try {
      message = JSON.parse(text);
    } catch {
      this.push({ dir: "in", kind: "invalid", ...this.body(text) });
      return;
    }
    if (typeof message?.id === "number" && !("method" in message)) {
      const request = this.pending.get(message.id);
      this.pending.delete(message.id);
      const latencyMs = request ? Math.round((this.clock() - request.startedAt) * 100) / 100 : undefined;
      if (latencyMs !== undefined) this.recordLatency(latencyMs);
      const failed = message.error !== undefined;
      if (failed) {
        this.counters.errors += 1;
        this.lastError = `${request?.method ?? `request ${message.id}`}: ${String(message.error?.message ?? "error")}`;
      }
      this.push({
        dir: "in",
        kind: failed ? "error" : "response",
        method: request?.method,
        id: message.id,
        latencyMs,
        ...this.body(text),
      });
      return;
    }
    this.push({
      dir: "in",
      kind: "notification",
      method: typeof message?.method === "string" ? message.method : undefined,
      ...this.body(text),
    });
  }

  /** A change of the socket: connecting, open, connected, close, error, reconnect scheduled, lost. */
  lifecycle(event: string, detail?: Record<string, unknown>): void {
    if (event === "connected") this.counters.connects += 1;
    if (event === "close") this.counters.closes += 1;
    if (event === "reconnect scheduled") this.counters.reconnects += 1;
    if (event === "error" || event === "connect failed")
      this.lastError = `${event}${detail?.message ? `: ${String(detail.message)}` : ""}`;
    if (event === "close") {
      // Requests still out when the socket closes never get a reply.
      for (const [id, request] of this.pending)
        this.push({ dir: "local", kind: "lifecycle", event: "abandoned", id, method: request.method });
      this.pending.clear();
    }
    this.push({ dir: "local", kind: "lifecycle", event, detail });
  }

  entries(): WireEntry[] {
    return this.log.slice();
  }

  stats(): WireStats {
    const sorted = [...this.latencies].sort((left, right) => left - right);
    return {
      entries: this.log.length,
      dropped: this.droppedCount,
      ...this.counters,
      inFlight: this.pending.size,
      lastError: this.lastError,
      latencyP50Ms: percentile(sorted, 0.5),
      latencyMaxMs: sorted.length ? sorted[sorted.length - 1] : undefined,
    };
  }

  /** The log as JSON Lines: a header line, then one line per entry, oldest first. */
  exportJsonl(header: Record<string, unknown> = {}): string {
    const lines = [
      JSON.stringify({
        type: "acp-wire-log",
        exportedAt: new Date(this.now()).toISOString(),
        ...header,
        stats: this.stats(),
      }),
    ];
    for (const entry of this.log) lines.push(JSON.stringify(entry));
    return `${lines.join("\n")}\n`;
  }

  clear(): void {
    this.log = [];
    this.bytes = 0;
    this.droppedCount = 0;
    this.latencies = [];
    this.notify();
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private body(text: string): Pick<WireEntry, "size" | "text" | "truncated"> {
    const truncated = text.length > MAX_PAYLOAD_CHARS;
    return {
      size: text.length,
      text: truncated ? text.slice(0, MAX_PAYLOAD_CHARS) : text,
      truncated: truncated || undefined,
    };
  }

  private recordLatency(latencyMs: number): void {
    this.latencies.push(latencyMs);
    if (this.latencies.length > MAX_ENTRIES) this.latencies.shift();
  }

  private push(entry: Omit<WireEntry, "seq" | "at">): void {
    const full: WireEntry = { seq: this.nextSeq++, at: this.now(), ...entry };
    this.log.push(full);
    this.bytes += full.text?.length ?? 0;
    while (this.log.length > MAX_ENTRIES || (this.bytes > MAX_TEXT_CHARS && this.log.length > 1)) {
      const dropped = this.log.shift()!;
      this.bytes -= dropped.text?.length ?? 0;
      this.droppedCount += 1;
    }
    this.notify();
  }

  private notify(): void {
    for (const listener of this.listeners) listener();
  }
}

/** The page's log. One agent pane is one page. */
export const acpWire = new AcpWireLog();
