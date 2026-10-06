// A time budget for each highlight job (highlightPool.ts). Pierre's pool hands one job at a time to
// each worker and has no deadline, so a grammar stuck on hostile input would hold its worker
// forever. WatchedWorker stands in for one Worker: when a file or diff job runs past
// HIGHLIGHT_BUDGET_MS it terminates the worker, starts a fresh one with the same setup messages,
// and answers the job with an error (Pierre then keeps the card's plain lines; onTimeout lets the
// card draw as PlainCode). A worker that fails before its first answer (a blocked script, a CSP
// mistake) is reported once through onStartFailure, and its pending setup jobs answer with an
// error, so the pool falls back to the main thread visibly instead of waiting forever.

/// How long one highlight job may run.
export const HIGHLIGHT_BUDGET_MS = 2_000;

type Clock = {
  setTimeout: (run: () => void, ms: number) => unknown;
  clearTimeout: (handle: never) => void;
};

type Options = {
  budgetMs?: number;
  clock?: Clock;
  /// A job ran out of time; `name` is its file's name (the card's id).
  onTimeout?: (name: string) => void;
  /// The worker failed before it answered anything.
  onStartFailure?: (reason: string) => void;
  /// The worker answered its first message.
  onReady?: () => void;
};

type Message = { type?: string; id?: string; file?: { name?: string; [key: string]: unknown }; diff?: { name?: string; [key: string]: unknown } };

const defaultClock: Clock = {
  setTimeout: (run, ms) => globalThis.setTimeout(run, ms),
  clearTimeout: (handle) => globalThis.clearTimeout(handle),
};

export class WatchedWorker extends EventTarget {
  private worker!: Worker;
  private readonly setup = new Map<string, Message>();
  private readonly jobs = new Map<string, { name: string; timer: unknown }>();
  private pendingSetup = new Set<string>();
  private answered = false;
  private failed = false;
  private readonly budget: number;
  private readonly clock: Clock;

  constructor(
    private readonly make: () => Worker,
    private readonly options: Options = {},
  ) {
    super();
    this.budget = options.budgetMs ?? HIGHLIGHT_BUDGET_MS;
    this.clock = options.clock ?? defaultClock;
    this.start();
  }

  private start(): void {
    const worker = this.make();
    this.worker = worker;
    worker.addEventListener("message", (event) => {
      if (worker !== this.worker) return; // a replaced worker's late answer
      this.received((event as MessageEvent).data as Message);
    });
    worker.addEventListener("error", () => {
      if (worker !== this.worker) return;
      if (!this.answered) this.startFailed();
      this.dispatchEvent(new Event("error"));
    });
  }

  private received(data: Message): void {
    if (!this.answered) {
      this.answered = true;
      this.options.onReady?.();
    }
    if (data?.id) {
      const job = this.jobs.get(data.id);
      if (job) {
        this.clock.clearTimeout(job.timer as never);
        this.jobs.delete(data.id);
      }
      this.pendingSetup.delete(data.id);
    }
    this.dispatchEvent(new MessageEvent("message", { data }));
  }

  private startFailed(): void {
    for (const id of this.pendingSetup) this.answerError(id, "the highlight worker failed to start");
    this.pendingSetup.clear();
    if (this.failed) return;
    this.failed = true;
    this.options.onStartFailure?.("the highlight worker failed to start");
  }

  private answerError(id: string, error: string): void {
    this.dispatchEvent(new MessageEvent("message", { data: { type: "error", id, error } }));
  }

  postMessage(message: Message): void {
    const id = message?.id;
    if (id && (message.type === "file" || message.type === "diff")) {
      const name = message.file?.name ?? message.diff?.name ?? "";
      const timer = this.clock.setTimeout(() => this.expire(id), this.budget);
      this.jobs.set(id, { name, timer });
    } else if (id && (message.type === "initialize" || message.type === "set-render-options")) {
      // The latest of each kind sets a fresh worker up the same way.
      this.setup.set(message.type, message);
      this.pendingSetup.add(id);
    }
    this.worker.postMessage(message);
  }

  private expire(id: string): void {
    const job = this.jobs.get(id);
    if (!job) return;
    this.jobs.delete(id);
    for (const other of this.jobs.values()) this.clock.clearTimeout(other.timer as never);
    const others = [...this.jobs.keys()];
    this.jobs.clear();
    this.worker.terminate();
    this.start();
    for (const message of this.setup.values()) this.worker.postMessage(message);
    this.answerError(id, "highlighting ran past its time budget");
    for (const other of others) this.answerError(other, "highlighting ran past its time budget");
    this.options.onTimeout?.(job.name);
  }

  terminate(): void {
    for (const job of this.jobs.values()) this.clock.clearTimeout(job.timer as never);
    this.jobs.clear();
    this.worker.terminate();
  }
}
