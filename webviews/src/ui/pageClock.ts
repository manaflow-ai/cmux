// Page-owned repeating work: a hidden page owns no timer, and the last subscriber releases
// both the timer and its visibility listener. Diagnostics count allocated timers, not callbacks.
import { useEffect, useState } from "react";

type Clock = { name: string; running: boolean; subscribers: () => number; document?: Document };
const clocks = new Set<Clock>();
const pageDocument = () => (typeof document === "undefined" ? undefined : document);

export function pageClocks(doc: Document | undefined = pageDocument()) {
  const items = [...clocks]
    .filter((clock) => clock.document === doc)
    .map((clock) => ({ name: clock.name, running: clock.running, subscribers: clock.subscribers() }));
  return {
    running: items.filter((clock) => clock.running).length,
    subscribers: items.reduce((total, clock) => total + clock.subscribers, 0),
    items,
  };
}

/** Starts repeating work only while visible. Showing the page starts a fresh deadline; callers
 * opt into an immediate catch-up for elapsed text, never for network/cache refresh work. */
export function visibleInterval(
  name: string,
  tick: () => void,
  every: number,
  options: { onShow?: () => void; aligned?: boolean; subscribers?: () => number } = {},
): () => void {
  const doc = pageDocument();
  const clock: Clock = { name, running: false, subscribers: options.subscribers ?? (() => 1), document: doc };
  let timer: ReturnType<typeof setTimeout> | undefined;
  let stopped = false;
  const clear = () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    clock.running = false;
  };
  const schedule = () => {
    if (stopped || doc?.visibilityState === "hidden") return;
    clock.running = true;
    timer = setTimeout(
      () => {
        timer = undefined;
        clock.running = false;
        if (stopped || doc?.visibilityState === "hidden") return;
        tick();
        schedule();
      },
      options.aligned ? every - (Date.now() % every) + 5 : every,
    );
  };
  const sync = () => {
    clear();
    if (stopped || doc?.visibilityState === "hidden") return;
    options.onShow?.();
    schedule();
  };
  clocks.add(clock);
  doc?.addEventListener("visibilitychange", sync);
  sync();
  return () => {
    stopped = true;
    clear();
    doc?.removeEventListener("visibilitychange", sync);
    clocks.delete(clock);
  };
}

/** One timer per cadence per page, regardless of the number of elapsed labels. */
function sharedClock(name: string, every: number, aligned = false) {
  const listeners = new Set<() => void>();
  let stop: (() => void) | undefined;
  const tick = () => {
    for (const listener of listeners) listener();
  };
  return (listener: () => void) => {
    // A subscription owns its own entry even if two callers pass the same callback.
    const notify = () => listener();
    listeners.add(notify);
    if (listeners.size === 1) {
      stop = visibleInterval(name, tick, every, { onShow: tick, aligned, subscribers: () => listeners.size });
    } else if (pageDocument()?.visibilityState !== "hidden") {
      notify();
    }
    return () => {
      listeners.delete(notify);
      if (listeners.size === 0) {
        stop?.();
        stop = undefined;
      }
    };
  };
}

export const subscribePageSecond = sharedClock("elapsed", 1_000);
export const subscribePageMinute = sharedClock("relative-time", 60_000, true);

/** Keep injected/remote clocks at the label; share only their scheduling. Inactive labels retain
 * their last sample, and showing a live page catches up from wall time rather than tick counts. */
export function usePageNow(running: boolean, now: () => number = Date.now): number {
  const [time, setTime] = useState(now);
  useEffect(() => {
    if (!running) return;
    return subscribePageSecond(() => setTime(now()));
  }, [running, now]);
  return time;
}
