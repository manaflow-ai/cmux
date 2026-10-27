// A reconnect's capped doubling backoff whose waits rest while the page is hidden
// (plans/cmux-next/chrome-parity/p13-webui.md, MQ4b, task 069). A hidden, frozen or parked page
// arms no timer and tries nothing; the show tries once at once (startPageTimeout's "check"), so a
// person coming back to a lost connection does not wait out a 30 s backoff. Chrome's own reconnects
// back off the same way (net/base/backoff_entry.cc), and a hidden page's timers are frozen with it.

import { type PagePollSeams, startPageTimeout } from "./pagePoll";

export interface RetryBackoffOptions extends PagePollSeams {
  /** The first wait. */
  firstMs: number;
  /** The longest wait; `schedule` can ask for a shorter cap. */
  maxMs: number;
  /** Multiplies each wait (a jitter in [0.5, 1) spreads many pages' retries); 1 by default. */
  jitter?: () => number;
}

/** One connection's retries: at most one wait at a time. */
export class RetryBackoff {
  private delayMs: number;
  private cancelWait: (() => void) | undefined;

  constructor(private readonly options: RetryBackoffOptions) {
    this.delayMs = options.firstMs;
  }

  /** Whether a retry is waiting. */
  get waiting(): boolean {
    return this.cancelWait !== undefined;
  }

  /** The next wait before its jitter. */
  get nextMs(): number {
    return this.delayMs;
  }

  /** Runs `attempt` after the next wait, replacing a waiting one; the wait after it doubles, up to `maxMs`. */
  schedule(attempt: () => void, maxMs = this.options.maxMs): void {
    this.cancel();
    const ms = this.delayMs * (this.options.jitter?.() ?? 1);
    this.delayMs = Math.min(this.delayMs * 2, maxMs, this.options.maxMs);
    const { lifecycle, timers } = this.options;
    this.cancelWait = startPageTimeout(
      () => {
        this.cancelWait = undefined;
        attempt();
      },
      ms,
      { lifecycle, timers, onResume: "check" },
    );
  }

  /** A connect succeeded or the person asked: the next wait is the first again. */
  reset(): void {
    this.delayMs = this.options.firstMs;
  }

  /** Drops the waiting retry. */
  cancel(): void {
    this.cancelWait?.();
    this.cancelWait = undefined;
  }
}
