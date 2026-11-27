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
//
// A job that waits only for the page to go quiet (`atRest`) also runs on the beat that puts the page to
// rest (`rest()`, pageHealth.ts): the rest is the quiet it waited for, so it never wakes a resting page
// by itself. With the page resting after one quiet beat, these jobs had been firing alone about 3.4 s
// into the rest instead.

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
  atRest: boolean;
  run: (atRest: boolean) => void;
}

export interface LaterOptions {
  /** The job waits only for the page to go quiet: it may run early, on the beat that rests the page,
   * which then tells it `atRest`. */
  atRest?: boolean;
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
  later(run: (atRest: boolean) => void, ms: number, slack = RIDE_SLACK_MS, options: LaterOptions = {}): number {
    const now = this.clock.now();
    const id = this.next++;
    const at = now + Math.max(0, ms);
    this.jobs.set(id, { at, by: at + Math.max(0, slack), atRest: options.atRest === true, run });
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

  /** The page goes to rest on this wake: run every job whose window opened, and every `atRest` job,
   * so nothing that only waited for quiet wakes the resting page. */
  rest(): void {
    this.runDue(true);
    this.arm();
  }

  /** Jobs waiting (for tests and `cmuxDebug`). */
  get size(): number {
    return this.jobs.size;
  }

  private runDue(resting = false): void {
    // A timer can fire a hair early; a job due within 1 ms runs now rather than wake the page again.
    const now = this.clock.now() + 1;
    // Over a copy: a job that asks again from its run waits for the next wake, even an `atRest` one.
    for (const [id, job] of [...this.jobs]) {
      const due = job.at <= now;
      if (!(due || (resting && job.atRest)) || !this.jobs.has(id)) continue;
      this.jobs.delete(id);
      try {
        job.run(resting && !due);
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
