// acpmux answers at most 64 work requests of one connection at a time and refuses the next with
// `connection.busy` (`REQUEST_WORK_LIMIT`, cmux-tui/crates/acpmux/src/server/mod.rs). A page whose
// replies come slowly (a chat on a loaded peer) kept sending, and a request it stopped waiting for
// still held the daemon's slot until its answer came: the next reads were refused and the pane drew
// "connection request limit reached". This budget is the page's copy of the daemon's count. A work
// read goes out only while fewer than WORK_LIMIT are unanswered, the rest wait in order, and one
// the page gave up on counts until its late answer arrives, as it does on the daemon. A busy reply
// to a read that still comes (a count that drifted) sends it again later, never at once. Writes and
// controls go out at once as before, and count.

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
/// A busy reply's first wait before the request goes again. The delay reaches BUSY_MAX_MS, but the
/// request remains pending while the socket is alive; it never becomes a terminal busy failure.
export const BUSY_BASE_MS = 250;
export const BUSY_MAX_MS = 4_000;
/// Busy reads retry for the life of their connection. `Infinity` is also a sentinel for controls,
/// which are never retried (`requestBudget` only retries methods with a send callback).
export const BUSY_TRIES = Number.POSITIVE_INFINITY;

/// The reads that wait for a slot and go again after a busy refusal: side-effect free, so a late
/// or repeated one changes nothing, and they are what floods a connection (a slow peer's chat list,
/// transcript pages, git status). Every other request goes out at once and is never sent again, as
/// it did before the budget: a write's order matters (a bookmark then its removal), and the host's
/// grant for a click or a scope lasts moments and is spent when the frame passes. It still counts.
const READS = new Set([
  "session/list",
  "acp.trust.get",
  "catalog.get",
  "trigger/chat.status",
  "git.status",
  "git.diff",
  "git.checkpoint.diff",
  "_acpmux/status",
  "_acpmux/info",
  "_acpmux/stats",
  "_acpmux/sessions",
  "_acpmux/events",
  "_acpmux/history",
  "_acpmux/attachment",
  "_acpmux/session_files",
  "_acpmux/native_history",
  "_acpmux/subagent_transcript",
  "_acpmux/subsession/get",
  "_acpmux/subsession/list",
  "_acpmux/workflows",
  "_acpmux/bookmark_get",
  "_acpmux/send_status",
  "_acpmux/process/list",
  "_acpmux/process/tail",
  "_acpmux/bg/list",
  "_acpmux/bg/output",
  "_acpmux/watch_ls",
  "_acpmux/queue_get",
  "_acpmux/draft_get",
  "_acpmux/composers",
  "_acpmux/file_put_status",
  "_acpmux/briefs",
  "_acpmux/tasks",
  "_acpmux/permission_groups",
  "_acpmux/approvers",
  "_acpmux/mac_approvers",
  "_acpmux/chats",
  "_acpmux/chats_search",
  "_acpmux/chat_roots",
  "_acpmux/chat_settings",
  "_acpmux/chat_transcript",
  "_acpmux/chat_projects",
  "_acpmux/handoff_get",
  "_acpmux/harnesses",
  "_acpmux/harness/icon",
  "_acpmux/harness/health",
  "_acpmux/registry",
  "_acpmux/defaults",
  "_acpmux/presets",
  "_acpmux/models",
  "_acpmux/directories",
  "_acpmux/route/list",
  "_acpmux/route/show",
  "_acpmux/web_modes",
  "_acpmux/schema",
  "_acpmux/protocol",
  "_acpmux/peers",
  "_acpmux/peer_status",
  "_acpmux/host_health",
  "_acpmux/pair_list",
  "_acpmux/machine_consent_get",
  "_acpmux/tailnet/state",
]);

export function countsAgainstBudget(method: string): boolean {
  return !UNCOUNTED.has(method);
}

/// Whether `method` waits for a slot and goes again after a busy refusal: reads only (`READS`).
export function waitsForSlot(method: string): boolean {
  return READS.has(method);
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
  private readonly unanswered = new Set<number | string>();
  private readonly waiting: { id: number | string; send: () => void }[] = [];
  /// Busy retries waiting for their time; cleared by `reset` (a closed connection).
  private readonly retries = new Map<number | string, ReturnType<typeof setTimeout>>();
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
  onWire(id: number | string): boolean {
    return this.unanswered.has(id);
  }

  /// Sends request `id` now, or once a slot frees when `limit` are unanswered. Only a read waits;
  /// any other request goes now whatever the count (the daemon's 64 leaves it room) and counts.
  admit(id: number | string, method: string, send: () => void): void {
    if (!countsAgainstBudget(method)) return send();
    if (!waitsForSlot(method)) return this.start(id, send);
    if (this.unanswered.size < this.limit && !this.waiting.length) return this.start(id, send);
    this.waiting.push({ id, send });
  }

  /// The daemon answered `id` (or the request never went): its slot frees.
  settled(id: number | string): void {
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
  retryLater(id: number | string, send: () => void, delayMs: number): void {
    this.settled(id);
    const timer = this.timers.set(() => {
      this.retries.delete(id);
      this.waiting.push({ id, send });
      this.pump();
    }, delayMs);
    this.retries.set(id, timer);
  }

  /// The connection closed: the daemon's count went with it. Returns the ids that never went.
  reset(): (number | string)[] {
    for (const timer of this.retries.values()) this.timers.clear(timer);
    const never = [...this.waiting.map((item) => item.id), ...this.retries.keys()];
    this.retries.clear();
    this.waiting.length = 0;
    this.unanswered.clear();
    return never;
  }

  private start(id: number | string, send: () => void): void {
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
