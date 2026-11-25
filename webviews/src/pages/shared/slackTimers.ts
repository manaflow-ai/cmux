// One shared timer for a page's deferred jobs, so they wake the page together, or not at all.
//
// A job that may run a little late (a sample to send, a copy to write once the page is quiet, a mode
// to drop once nothing happened) asks for a window, `[ms, ms + slack]`, instead of a time. The page
// arms one timer, at the earliest window's end, and every wake runs each job whose window opened:
// the timer's own, and any other wake that calls `ride()` (the health heartbeat, pageHealth.ts, which
// ticks every HEARTBEAT_MS while the page is visible and not at rest). A job with RIDE_SLACK_MS of
// slack therefore never wakes a beating page by itself; on a page at rest it runs at its window's end.
//
// Before, the chat's 5 s at rest after a switch woke the page 6 times (bench/chat-switch.bench.ts,
// `idle_wakeups`, FIXTURE=god): 3 beats, and one timer each for the snapshot's quiet write
// (chatSnapshot/live.ts), the frame budget's rest (frameBudget.ts) and the frame tally's flush
// (frameTally.ts). On this scheduler the three jobs ride the beats.

/** Slack that spans one heartbeat period (pageHealth.ts HEARTBEAT_MS, 2 s) and a little more, so a
 * job's window always holds a beat, and its own deadline never races the beat right at its end. */
export const RIDE_SLACK_MS = 2_250;

export interface SlackClock {
  now(): number;
  set(callback: () => void, ms: number): unknown;
  clear(handle: unknown): void;
}

interface Job {
  at: number;
  by: number;
  run: () => void;
}

type TimerHost = Pick<typeof globalThis, "setTimeout" | "clearTimeout">;

/** The window's own timers, looked up at each call (a test may swap them in after). */
const windowClock = (view: TimerHost): SlackClock => ({
  now: () => (typeof performance !== "undefined" ? performance.now() : Date.now()),
  set: (callback, ms) => view.setTimeout(callback, ms),
  clear: (handle) => view.clearTimeout(handle as ReturnType<typeof setTimeout>),
});

export class SlackTimers {
  private jobs = new Map<number, Job>();
  private next = 1;
  private armed: { handle: unknown; by: number } | undefined;

  constructor(private readonly clock: SlackClock = windowClock(globalThis)) {}

  /** Runs `run` once, `ms` to `ms + slack` from now; returns its id for `cancel`. */
  later(run: () => void, ms: number, slack = RIDE_SLACK_MS): number {
    const now = this.clock.now();
    const id = this.next++;
    const at = now + Math.max(0, ms);
    this.jobs.set(id, { at, by: at + Math.max(0, slack), run });
    this.arm();
    return id;
  }

  cancel(id: number | undefined): void {
    if (id === undefined || !this.jobs.delete(id)) return;
    this.arm();
  }

  /** The page woke for something else: run every job whose window opened, so none wakes it again. */
  ride(): void {
    this.runDue();
    this.arm();
  }

  /** Jobs waiting (for tests and `cmuxDebug`). */
  get size(): number {
    return this.jobs.size;
  }

  private runDue(): void {
    // A timer can fire a hair early; a job due within 1 ms runs now rather than wake the page again.
    const now = this.clock.now() + 1;
    for (const [id, job] of this.jobs) {
      if (job.at > now || !this.jobs.has(id)) continue;
      this.jobs.delete(id);
      try {
        job.run();
      } catch (error) {
        // One job's throw must not keep the others from running.
        queueMicrotask(() => {
          throw error;
        });
      }
    }
  }

  private arm(): void {
    let by = Infinity;
    for (const job of this.jobs.values()) by = Math.min(by, job.by);
    if (this.armed && this.armed.by === by) return;
    if (this.armed) this.clock.clear(this.armed.handle);
    this.armed = undefined;
    if (by === Infinity) return;
    const handle = this.clock.set(
      () => {
        if (this.armed?.handle !== handle) return;
        this.armed = undefined;
        this.runDue();
        this.arm();
      },
      Math.max(0, by - this.clock.now()),
    );
    this.armed = { handle, by };
  }
}

const byWindow = new WeakMap<object, SlackTimers>();

/** A window's scheduler: every job in it shares its one timer, and its heartbeat rides them all. */
export function slackTimersFor(view: TimerHost = globalThis): SlackTimers {
  let timers = byWindow.get(view);
  if (!timers) {
    timers = new SlackTimers(windowClock(view));
    byWindow.set(view, timers);
  }
  return timers;
}
