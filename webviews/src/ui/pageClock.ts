// Page-owned repeating work: a hidden page owns no timer, and the last subscriber releases
// both the timer and its visibility listener. Diagnostics count allocated timers, not callbacks.
import { useEffect, useRef, useState } from "react";

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

/** One timer per cadence per page, regardless of the number of elapsed labels. Every listener gets
 * the same sample of the time (`at`), and one that joins gets the clock's last sample at once, not a
 * fresh read: a label mounted between two ticks (a hat line that opens) shows the same second as the
 * labels already there, so a header never reads a second behind the line it sums. */
function sharedClock(name: string, every: number, aligned = false) {
  const listeners = new Set<(at: number) => void>();
  let stop: (() => void) | undefined;
  let at: number | undefined;
  const tick = () => {
    at = Date.now();
    for (const listener of listeners) listener(at);
  };
  const subscribe = (listener: (at: number) => void) => {
    // A subscription owns its own entry even if two callers pass the same callback.
    const notify = (sample: number) => listener(sample);
    listeners.add(notify);
    if (listeners.size === 1) {
      at = Date.now();
      stop = visibleInterval(name, tick, every, { onShow: tick, aligned, subscribers: () => listeners.size });
    }
    if (pageDocument()?.visibilityState !== "hidden") notify(at ?? Date.now());
    return () => {
      listeners.delete(notify);
      if (listeners.size === 0) {
        stop?.();
        stop = undefined;
        at = undefined;
      }
    };
  };
  /** The clock's last sample while it has listeners on a shown page, else undefined. */
  const sample = () => (listeners.size > 0 && pageDocument()?.visibilityState !== "hidden" ? at : undefined);
  return Object.assign(subscribe, { sample });
}

/** One timer for timestamp labels, at the nearest actual text change. Removing the last label
 * removes its timer; hidden pages catch up once before choosing a new deadline.
 * A label joining or leaving costs O(1): a chat switch unmounts one chat's labels and mounts the
 * next one's (two per row: an age and a copy time), and rebuilding the timer and its nearest deadline
 * (a scan of every label) on each of them was quadratic, 10 to 25 ms of a 120-turn chat's switch
 * (bench/settled-page.bench.ts chat_switch). The timer is rebuilt only for a label due before it
 * fires; one that leaves leaves the timer as it is, which, firing early, finds no label due and
 * sets the next deadline from the labels left. */
const deadlines = new Set<{ notify: () => void; next: () => number; at: number }>();
let stopDeadlines: (() => void) | undefined;
/// The deadline the timer waits for, as its last scheduling read it (Infinity when none).
let deadlineDue = Number.POSITIVE_INFINITY;
function scheduleDeadlines() {
  stopDeadlines?.();
  stopDeadlines = undefined;
  deadlineDue = Number.POSITIVE_INFINITY;
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
    () => {
      let due = Number.POSITIVE_INFINITY;
      for (const label of deadlines) if (label.at < due) due = label.at;
      deadlineDue = due;
      return due - Date.now() + 5;
    },
    { onShow: tick, subscribers: () => deadlines.size },
  );
}

export function subscribePageDeadline(notify: () => void, next: () => number): () => void {
  const label = { notify, next, at: next() };
  deadlines.add(label);
  // A timer that already fires at or before this label's change covers it; a hidden page's sets
  // its deadline from every label when the page shows.
  if (!stopDeadlines || (label.at < deadlineDue && pageDocument()?.visibilityState !== "hidden")) scheduleDeadlines();
  return () => {
    if (!deadlines.delete(label)) return;
    if (deadlines.size === 0) scheduleDeadlines();
  };
}

export const subscribePageSecond = sharedClock("elapsed", 1_000);
export const subscribePageMinute = sharedClock("relative-time", 60_000, true);

/** The wall time for one label that wakes only when its own words change: `next(now)` is when they
 * next do (after `now`). Every such label shares the page's one deadline timer
 * (`subscribePageDeadline`), so a list of "4 min" stamps draws only the stamps whose words moved,
 * never their rows. `fixed` pins the time (a gallery, a test) and holds no timer. The time is read
 * when the label mounts: key a label by the time it counts from, so a new one reads afresh. */
export function useDeadlineNow(next: (now: number) => number, fixed?: number): number {
  const [time, setTime] = useState(() => fixed ?? Date.now());
  useEffect(() => {
    if (fixed !== undefined) return;
    return subscribePageDeadline(
      () => setTime(Date.now()),
      () => next(Date.now()),
    );
  }, [next, fixed]);
  return fixed ?? time;
}

/** Keep injected/remote clocks at the label; share only their scheduling. Inactive labels retain
 * their last sample, and showing a live page catches up from wall time rather than tick counts. */
export function usePageNow(running: boolean, now: () => number = Date.now): number {
  // On the wall clock, a running label starts at the shared clock's sample, as its next ticks are.
  const wall = now === Date.now;
  const [time, setTime] = useState(() => (running && wall ? (subscribePageSecond.sample() ?? now()) : now()));
  // The sample it shows, so subscribing (which hands over the current sample at once) sets nothing when
  // the label already shows it: React can't always drop an equal set unasked, and then it renders and commits.
  const shown = useRef(time);
  useEffect(() => {
    if (!running) return;
    return subscribePageSecond((at) => {
      const sample = wall ? at : now();
      if (sample === shown.current) return;
      shown.current = sample;
      setTime(sample);
    });
  }, [running, now, wall]);
  return time;
}
