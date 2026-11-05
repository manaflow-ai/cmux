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
  every: number | (() => number | null),
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
    const delay = typeof every === "function" ? every() : every;
    if (delay === null || !Number.isFinite(delay)) return;
    clock.running = true;
    timer = setTimeout(
      () => {
        timer = undefined;
        clock.running = false;
        if (stopped || doc?.visibilityState === "hidden") return;
        tick();
        schedule();
      },
      Math.min(2_147_483_647, Math.max(1, options.aligned ? delay - (Date.now() % delay) + 5 : delay)),
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

/** One timer for timestamp labels, at the nearest actual text change. Removing the last label
 * removes its timer; hidden pages catch up once before choosing a new deadline. */
const deadlines = new Set<{ notify: () => void; next: () => number; at: number }>();
let stopDeadlines: (() => void) | undefined;
function scheduleDeadlines() {
  stopDeadlines?.();
  stopDeadlines = undefined;
  if (deadlines.size === 0) return;
  const tick = () => {
    for (const label of deadlines) {
      if (label.at > Date.now()) continue;
      label.at = label.next();
      label.notify();
    }
  };
  stopDeadlines = visibleInterval(
    "relative-time",
    tick,
    () => Math.min(...Array.from(deadlines, (label) => label.at)) - Date.now() + 5,
    { onShow: tick, subscribers: () => deadlines.size },
  );
}

export function subscribePageDeadline(notify: () => void, next: () => number): () => void {
  const label = { notify, next, at: next() };
  deadlines.add(label);
  scheduleDeadlines();
  return () => {
    deadlines.delete(label);
    scheduleDeadlines();
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
