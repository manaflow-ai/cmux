// One clock per page for every label that shows the time or an elapsed time.
//
// Each granularity (a second, a minute) runs at most one setTimeout chain per page, however many
// labels read it, and each wake lands on the wall-clock boundary of its period, so all labels on the
// page step together and the page wakes once per period. This is Chrome's aligned wake-up: a
// throttled timer runs on the next multiple of its wake-up interval
// (third_party/blink/renderer/platform/scheduler/common/throttling/wake_up_budget_pool.cc), and a
// hidden page's timers stop (page_scheduler_impl.cc). The chain runs only while the page is active
// (PageLifecycle) and someone subscribes. When the page shows again it ticks once if a boundary
// passed while it was hidden, then aligns again.

import { type PageLifecycle, type PageLifecycleState, pageLifecycleFor } from "../pages/shared/pageLifecycle";

/** How often a clock ticks: on each second or each minute of the wall clock. */
export type ClockGranularity = "second" | "minute";

const PERIOD_MS: Record<ClockGranularity, number> = { second: 1000, minute: 60_000 };

/** The period of `granularity` in milliseconds. */
export function clockPeriodMs(granularity: ClockGranularity): number {
  return PERIOD_MS[granularity];
}

/** The start of the period of `granularity` that holds `time` (epoch milliseconds). */
export function clockFloor(time: number, granularity: ClockGranularity): number {
  const period = PERIOD_MS[granularity];
  return Math.floor(time / period) * period;
}

/** The timer seam: the page's wall clock and one-shot timers, or a fake clock in tests. */
export interface ClockTimers {
  now(): number;
  after(ms: number, callback: () => void): unknown;
  cancel(handle: unknown): void;
}

export const browserClockTimers: ClockTimers = {
  now: () => Date.now(),
  // wakeup-allow: bounded page clock, visible and subscribed only; one aligned timeout per granularity.
  after: (ms, callback) => setTimeout(callback, ms),
  cancel: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/** One granularity's subscribers and its one pending timeout. */
class ClockChannel {
  readonly listeners = new Set<() => void>();
  private handle: unknown;
  private armed = false;
  /** The period start of the last tick the subscribers saw. */
  private seen = 0;

  constructor(
    private readonly granularity: ClockGranularity,
    private readonly timers: ClockTimers,
  ) {}

  /** The first subscriber came: note the current period, and arm the next boundary if `active`. */
  open(active: boolean): void {
    const now = this.timers.now();
    this.seen = clockFloor(now, this.granularity);
    if (active && !this.armed) this.arm(now);
  }

  /** Cancels the pending timeout. */
  stop(): void {
    if (!this.armed) return;
    this.timers.cancel(this.handle);
    this.armed = false;
    this.handle = undefined;
  }

  /** The page shows again: tick once if a boundary passed while it was hidden, then align. */
  resume(): void {
    if (this.armed) return;
    const now = this.timers.now();
    const current = clockFloor(now, this.granularity);
    const missed = current > this.seen;
    this.seen = current;
    this.arm(now);
    if (missed) this.notify();
  }

  private arm(now: number): void {
    const period = PERIOD_MS[this.granularity];
    // The next boundary strictly after now: a timeout that fires a little early still lands in the
    // period it was armed for and re-arms for the boundary it missed by that margin.
    const delay = clockFloor(now, this.granularity) + period - now;
    this.armed = true;
    this.handle = this.timers.after(delay, this.fire);
  }

  private readonly fire = (): void => {
    this.armed = false;
    this.handle = undefined;
    const now = this.timers.now();
    const current = clockFloor(now, this.granularity);
    this.arm(now);
    if (current === this.seen) return;
    this.seen = current;
    this.notify();
  };

  private notify(): void {
    for (const listener of this.listeners) listener();
  }
}

/**
 * A page's clock. Subscribing to a granularity is ref-counted: the first subscriber starts its
 * timeout chain, the last one to leave stops it, and the page's lifecycle is observed only while
 * there is a subscriber.
 */
export class PageClock {
  private readonly channels = new Map<ClockGranularity, ClockChannel>();
  private subscribers = 0;
  private unobserve: (() => void) | undefined;

  constructor(
    private readonly lifecycle: PageLifecycle,
    private readonly timers: ClockTimers = browserClockTimers,
  ) {}

  /**
   * The start of the current second, for every granularity: a granularity sets only how often a
   * subscriber wakes, never what it reads. The value changes only on a second boundary, so labels on
   * the page read the same time and a React snapshot stays stable, and it never goes back when a label
   * moves from second to minute granularity.
   */
  now(): number {
    return clockFloor(this.timers.now(), "second");
  }

  /** Calls `listener` on each boundary of `granularity` while the page is active; returns the
      unsubscribe function. */
  subscribe(granularity: ClockGranularity, listener: () => void): () => void {
    let channel = this.channels.get(granularity);
    if (!channel) {
      channel = new ClockChannel(granularity, this.timers);
      this.channels.set(granularity, channel);
    }
    // A listener can subscribe twice; wrap it so each subscription counts once.
    const entry = () => listener();
    channel.listeners.add(entry);
    this.subscribers += 1;
    if (this.subscribers === 1) this.unobserve = this.lifecycle.observe(this.lifecycleChanged);
    if (channel.listeners.size === 1) channel.open(this.lifecycle.state() === "active");
    let subscribed = true;
    return () => {
      if (!subscribed) return;
      subscribed = false;
      channel.listeners.delete(entry);
      this.subscribers -= 1;
      if (channel.listeners.size === 0) channel.stop();
      if (this.subscribers > 0) return;
      this.unobserve?.();
      this.unobserve = undefined;
    };
  }

  private readonly lifecycleChanged = (state: PageLifecycleState): void => {
    for (const channel of this.channels.values()) {
      if (channel.listeners.size === 0) continue;
      if (state === "active") channel.resume();
      else channel.stop();
    }
  };
}

const clocks = new WeakMap<PageLifecycle, PageClock>();

/** The clock of the page whose lifecycle is `lifecycle` (the current document's by default), made
    once per page. */
export function pageClockFor(lifecycle: PageLifecycle = pageLifecycleFor()): PageClock {
  let clock = clocks.get(lifecycle);
  if (!clock) {
    clock = new PageClock(lifecycle);
    clocks.set(lifecycle, clock);
  }
  return clock;
}
