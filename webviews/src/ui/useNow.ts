// The time for a label that shows it, read from the page's one clock (pageClock.ts).
//
// A component calls `useNow("second")` (or "minute" for a label that changes once a minute, such as
// an elapsed time past 60 s) and re-renders on each boundary of that period while the page shows.
// Hidden, it does not re-render; it ticks once on show if a boundary passed. Never setInterval.

import { useCallback, useSyncExternalStore } from "react";
import { type ClockGranularity, type PageClock, pageClockFor } from "./pageClock";

export interface UseNowOptions {
  /** The page's clock; a test passes one on a fake lifecycle and fake timers. */
  clock?: PageClock;
  /** False stops the subscription (a label that shows no time now); the value still reads. */
  enabled?: boolean;
}

/**
 * The start of the current second (epoch milliseconds), the same for every label on the page. An
 * elapsed time is `useNow(...) - start`, clamped at 0. `granularity` sets only how often the label
 * re-renders: at "minute" it reads the same time as at "second", so it never goes back on a switch.
 */
export function useNow(granularity: ClockGranularity = "second", options: UseNowOptions = {}): number {
  const clock = options.clock ?? pageClockFor();
  const enabled = options.enabled ?? true;
  const subscribe = useCallback(
    (notify: () => void) => (enabled ? clock.subscribe(granularity, notify) : () => undefined),
    [clock, granularity, enabled],
  );
  const snapshot = useCallback(() => clock.now(), [clock]);
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}
