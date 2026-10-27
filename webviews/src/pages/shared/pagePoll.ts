// Polls that rest while the page is hidden (plans/cmux-next/chrome-parity/p13-webui.md, MQ4b, task 069).
//
// A poll is one timer at a time: it runs its read, waits for the read to settle, then arms the next
// period, so reads never overlap and a slow host stretches the period instead of queueing reads.
// While the page is hidden, frozen or parked (pageLifecycle.ts) it arms nothing. Chrome freezes a
// hidden page's task queues and, on resume, runs a timer whose time came once
// (third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.cc, SetPageFrozen);
// a cmux page rests from the hide on, and on show either checks once (`onResume: "check"`) or waits
// one period (`"wait"`, the agent page, where a show reads nothing: check-switch-fetches.py).

import { type PageLifecycle, type PageLifecycleState, pageLifecycleFor } from "./pageLifecycle";

/** The one-shot timer seam: the page's own `setTimeout`, or a fake clock in tests. */
export interface PollTimers {
  after(ms: number, callback: () => void): unknown;
  cancel(handle: unknown): void;
}

/** The page's timers, read at each call so a test's fake clock takes them over. */
export const browserPollTimers: PollTimers = {
  after: (ms, callback) => setTimeout(callback, ms),
  cancel: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/** What a show after a hide does: run once now, or arm one period. */
export type PollResume = "check" | "wait";

/** What a poll runs on: the page's lifecycle and timers by default, fakes in tests. */
export interface PagePollSeams {
  lifecycle?: PageLifecycle;
  timers?: PollTimers;
}

export interface PagePollOptions extends PagePollSeams {
  /** Runs once at the start while the page is active (the default); false waits one period first. */
  immediate?: boolean;
  /** "check" (the default) runs once on show; "wait" arms one period and reads nothing on show. */
  onResume?: PollResume;
}

/** One run of a poll. `resumed`: the run is the check a show made after a hide. */
export interface PollTick {
  readonly resumed: boolean;
}

/** A poll's read: return `false` (or a promise of it) to stop. A rejected read keeps polling. */
export type PollRun = (tick: PollTick) => unknown;

const isThenable = (value: unknown): value is PromiseLike<unknown> =>
  typeof (value as { then?: unknown } | null)?.then === "function";

/**
 * Runs `run` every `ms` while the page is active, counting each period from the end of the last
 * run. Returns the stop function.
 *
 * ```ts
 * const stop = startPagePoll(() => store.load(url), 5_000, { immediate: false });
 * ```
 */
export function startPagePoll(run: PollRun, ms: number, options: PagePollOptions = {}): () => void {
  const lifecycle = options.lifecycle ?? pageLifecycleFor();
  const timers = options.timers ?? browserPollTimers;
  const onResume = options.onResume ?? "check";
  let handle: unknown;
  let armed = false;
  let running = false;
  let stopped = false;
  // A hide came since the last run started: the next run on show is a resume.
  let rested = false;

  const disarm = () => {
    if (armed) timers.cancel(handle);
    armed = false;
    handle = undefined;
  };
  const next = () => {
    if (stopped || running || armed || lifecycle.state() !== "active") return;
    if (rested && onResume === "check") return tick(true);
    rested = false;
    armed = true;
    handle = timers.after(ms, () => {
      armed = false;
      handle = undefined;
      tick(false);
    });
  };
  const settle = (value: unknown) => {
    running = false;
    if (value === false) stop();
    else next();
  };
  function tick(resumed: boolean): void {
    if (stopped) return;
    rested = false;
    running = true;
    let value: unknown;
    try {
      value = run({ resumed });
    } catch (error) {
      running = false;
      stop();
      throw error;
    }
    if (isThenable(value)) value.then(settle, () => settle(undefined));
    else settle(value);
  }
  const changed = (state: PageLifecycleState) => {
    if (state === "active") return next();
    disarm();
    rested = true;
  };
  const unobserve = lifecycle.observe(changed);
  function stop(): void {
    if (stopped) return;
    stopped = true;
    unobserve();
    disarm();
  }

  const immediate = options.immediate !== false;
  if (lifecycle.state() === "active" && immediate) tick(false);
  else {
    // A poll started hidden owes its first run to the show, as a resume does.
    rested = immediate;
    next();
  }
  return stop;
}

export interface PageTimeoutOptions extends PagePollSeams {
  /** "check" (the default) runs at once on a show after a hide; "wait" counts the whole `ms` again. */
  onResume?: PollResume;
}

/**
 * Runs `run` once, after `ms` of the page being active: a retry backoff, or a bounded poll's next
 * round. While the page is hidden, frozen or parked no timer is armed; a show then runs it at once
 * ("check": a reconnect the person comes back to) or counts `ms` again ("wait": the agent page,
 * where a show reads nothing). A timeout started hidden counts as one that rested. Returns the
 * cancel function.
 *
 * ```ts
 * const cancel = startPageTimeout(() => void connect(), backoff);
 * ```
 */
export function startPageTimeout(run: () => void, ms: number, options: PageTimeoutOptions = {}): () => void {
  const lifecycle = options.lifecycle ?? pageLifecycleFor();
  const timers = options.timers ?? browserPollTimers;
  const onResume = options.onResume ?? "check";
  let handle: unknown;
  let armed = false;
  let done = false;

  const disarm = () => {
    if (armed) timers.cancel(handle);
    armed = false;
    handle = undefined;
  };
  const arm = () => {
    armed = true;
    handle = timers.after(ms, () => {
      armed = false;
      handle = undefined;
      fire();
    });
  };
  const unobserve = lifecycle.observe((state) => {
    if (state !== "active") return disarm();
    if (armed) return;
    if (onResume === "check") fire();
    else arm();
  });
  function cancel(): void {
    if (done) return;
    done = true;
    unobserve();
    disarm();
  }
  function fire(): void {
    if (done) return;
    cancel();
    run();
  }

  if (lifecycle.state() === "active") arm();
  return cancel;
}
