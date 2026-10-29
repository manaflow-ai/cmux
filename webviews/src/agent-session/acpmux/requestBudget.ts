// acpmux answers at most 64 work requests of one connection at a time and refuses the next with
// `connection.busy` (`REQUEST_WORK_LIMIT`, cmux-tui/crates/acpmux/src/server/mod.rs). A page whose
// replies come slowly (a chat on a loaded peer) kept sending, and a request it stopped waiting for
// still held the daemon's slot until its answer came: the next reads were refused and the pane drew
// "connection request limit reached". This budget is the page's copy of the daemon's count. A work
// request goes out only while fewer than WORK_LIMIT are unanswered, the rest wait in order, and one
// the page gave up on counts until its late answer arrives, as it does on the daemon. A busy reply
// that still comes (a count that drifted) sends the request again later, never at once.

/// Methods the daemon does not count (`request_uses_work_budget`); they go out at once.
const UNCOUNTED = new Set([
  "session/new",
  "session/load",
  "session/resume",
  "session/fork",
  "session/prompt",
  "_acpmux/attach",
  "_acpmux/wait",
]);

/// Below the daemon's 64, so a page never meets its refusal from its own requests.
export const WORK_LIMIT = 48;
/// A busy reply's first wait before the request goes again; doubles per refusal up to BUSY_MAX_MS.
export const BUSY_BASE_MS = 250;
export const BUSY_MAX_MS = 4_000;
/// Refusals one request takes before its caller sees the busy error.
export const BUSY_TRIES = 6;

export function countsAgainstBudget(method: string): boolean {
  return !UNCOUNTED.has(method);
}

/// The wait before try `attempt` (1-based) of a refused request: exponential, with full jitter so
/// requests refused together do not go again together.
export function busyDelay(attempt: number, random: () => number = Math.random): number {
  const cap = Math.min(BUSY_MAX_MS, BUSY_BASE_MS * 2 ** Math.max(0, attempt - 1));
  return Math.round(cap / 2 + (random() * cap) / 2);
}

type Timers = {
  set(run: () => void, ms: number): ReturnType<typeof setTimeout>;
  clear(timer: ReturnType<typeof setTimeout>): void;
};

const realTimers: Timers = {
  set: (run, ms) => setTimeout(run, ms),
  clear: (timer) => clearTimeout(timer),
};

/// One connection's unanswered work requests, by request id. `send` puts a request on the wire;
/// the budget calls it when the request may go.
export class RequestBudget {
  /// Ids on the wire that the daemon counts: answered or not by the caller, until their reply.
  private readonly unanswered = new Set<number>();
  private readonly waiting: { id: number; send: () => void }[] = [];
  /// Busy retries waiting for their time; cleared by `reset` (a closed connection).
  private readonly retries = new Map<number, ReturnType<typeof setTimeout>>();
  /// The most this connection had unanswered at once (perf harness, wire log).
  peak = 0;

  constructor(
    private readonly limit = WORK_LIMIT,
    private readonly timers: Timers = realTimers,
  ) {}

  get inFlight(): number {
    return this.unanswered.size;
  }

  get queued(): number {
    return this.waiting.length;
  }

  /// Whether `id` went out and the daemon still counts it.
  onWire(id: number): boolean {
    return this.unanswered.has(id);
  }

  /// Sends request `id` now, or once a slot frees when `limit` are unanswered.
  admit(id: number, method: string, send: () => void): void {
    if (!countsAgainstBudget(method)) return send();
    if (this.unanswered.size < this.limit && !this.waiting.length) return this.start(id, send);
    this.waiting.push({ id, send });
  }

  /// The daemon answered `id` (or the request never went): its slot frees.
  settled(id: number): void {
    const timer = this.retries.get(id);
    if (timer !== undefined) {
      this.timers.clear(timer);
      this.retries.delete(id);
    }
    const queuedAt = this.waiting.findIndex((item) => item.id === id);
    if (queuedAt >= 0) this.waiting.splice(queuedAt, 1);
    if (this.unanswered.delete(id)) this.pump();
  }

  /// The daemon refused `id` as busy: its slot frees now and it goes again after `delayMs`, behind
  /// whatever waits then.
  retryLater(id: number, send: () => void, delayMs: number): void {
    this.settled(id);
    const timer = this.timers.set(() => {
      this.retries.delete(id);
      this.waiting.push({ id, send });
      this.pump();
    }, delayMs);
    this.retries.set(id, timer);
  }

  /// The connection closed: the daemon's count went with it. Returns the ids that never went.
  reset(): number[] {
    for (const timer of this.retries.values()) this.timers.clear(timer);
    const never = [...this.waiting.map((item) => item.id), ...this.retries.keys()];
    this.retries.clear();
    this.waiting.length = 0;
    this.unanswered.clear();
    return never;
  }

  private start(id: number, send: () => void): void {
    this.unanswered.add(id);
    this.peak = Math.max(this.peak, this.unanswered.size);
    send();
  }

  private pump(): void {
    while (this.unanswered.size < this.limit && this.waiting.length) {
      const next = this.waiting.shift()!;
      this.start(next.id, next.send);
    }
  }
}
