import { useSyncExternalStore } from "react";
import { pageLifecycleFor, type PageLifecycleState } from "../../pages/shared/pageLifecycle";

/// One clock for every relative time the pane draws ("now", "5m"): it reads the wall clock's minute,
/// so two pages (two New Tabs, All chats) show the same age for the same timestamp and change it in
/// the same frame (Leo 2026-10-13: one New Tab said "1m" while the other said "now").
export const CLOCK_TICK_MS = 60_000;

/// `at` down to its minute: every page reading the clock in the same minute gets the same time.
export const clockTime = (at = Date.now()) => Math.floor(at / CLOCK_TICK_MS) * CLOCK_TICK_MS;

const listeners = new Set<() => void>();
let timer: ReturnType<typeof setTimeout> | undefined;
let unobserveLifecycle: (() => void) | undefined;

const notify = () => {
  for (const listener of listeners) listener();
};

function schedule() {
  // Just past the next minute, so the read lands in it.
  timer = setTimeout(
    () => {
      timer = undefined;
      notify();
      if (listeners.size > 0) schedule();
    },
    CLOCK_TICK_MS - (Date.now() % CLOCK_TICK_MS) + 5,
  );
}

function cancel() {
  if (timer) clearTimeout(timer);
  timer = undefined;
}

/// The clock ticks only while the page is active (pages/shared/pageLifecycle.ts): a
/// hidden or frozen page arms no timer, where Chrome throttles a hidden page's timers
/// (third_party/blink/renderer/platform/scheduler/main_thread/page_scheduler_impl.cc). On show it
/// reads the minute once, so the ages are the ones a page that never hid shows; it reads no data.
function lifecycleChanged(state: PageLifecycleState) {
  if (state !== "active") return cancel();
  if (timer) return;
  notify();
  schedule();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  if (!unobserveLifecycle) {
    const lifecycle = pageLifecycleFor();
    unobserveLifecycle = lifecycle.observe(lifecycleChanged);
    if (lifecycle.state() === "active") schedule();
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size > 0) return;
    unobserveLifecycle?.();
    unobserveLifecycle = undefined;
    cancel();
  };
}

const read = () => clockTime();

/// The shared clock's time; re-renders the caller each minute while the page is active.
export function useMinuteClock(): number {
  return useSyncExternalStore(subscribe, read, read);
}
