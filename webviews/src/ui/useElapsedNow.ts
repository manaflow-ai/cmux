// The time a running elapsed label ("Working for 42s", "Thinking 3m") reads from the page clock
// (pageClock.ts).
//
// Under a minute the label counts seconds and re-renders on each second. From one minute on it shows
// whole minutes and re-renders once a minute, so a page of running clocks wakes once a minute, not
// once a second. Chrome's duration labels drop the seconds the same way past a minute
// (ui/base/l10n/time_format.cc, TimeFormat::Simple), and its throttled timers wake on aligned
// boundaries (third_party/blink/renderer/platform/scheduler/common/throttling/wake_up_budget_pool.cc).

import { type ClockGranularity, clockFloor, pageClockFor } from "./pageClock";
import { type UseNowOptions, useNow } from "./useNow";

/** From this elapsed time on, a running label shows whole minutes and ticks once a minute. */
export const ELAPSED_MINUTE_MS = 60_000;

/** The elapsed time a running label shows for `ms`: itself (at least 0) under a minute, whole
    minutes from one minute on. A finished time is shown as it is. */
export function shownElapsed(ms: number): number {
  if (ms < ELAPSED_MINUTE_MS) return Math.max(0, ms);
  return clockFloor(ms, "minute");
}

/** How often a label timing from `since` ticks when the clock reads `now`: each second under a
    minute, each minute after. With no `since`, each second. */
export function elapsedGranularity(since: number | undefined, now: number): ClockGranularity {
  return since !== undefined && now - since >= ELAPSED_MINUTE_MS ? "minute" : "second";
}

/**
 * The page clock's time (the current second, pageClock.ts) for a label that times from `since`
 * (epoch milliseconds, this computer's clock). It re-renders the label each second while the time
 * is under a minute and each minute after; with no `since`, each second. `enabled: false` stops the
 * ticks (a finished or held label).
 */
export function useElapsedNow(since: number | undefined, options: UseNowOptions = {}): number {
  const clock = options.clock ?? pageClockFor();
  return useNow(elapsedGranularity(since, clock.now()), { clock, enabled: options.enabled ?? true });
}
