import { useSyncExternalStore } from "react";
import { subscribePageMinute } from "../../ui/pageClock";

/// One clock for every relative time the pane draws ("now", "5m"): it reads the wall clock's minute,
/// so two pages (two New Tabs, All chats) show the same age for the same timestamp and change it in
/// the same frame (Leo 2026-10-13: one New Tab said "1m" while the other said "now").
export const CLOCK_TICK_MS = 60_000;

/// `at` down to its minute: every page reading the clock in the same minute gets the same time.
export const clockTime = (at = Date.now()) => Math.floor(at / CLOCK_TICK_MS) * CLOCK_TICK_MS;

const read = () => clockTime();

/// The shared clock's time; re-renders the caller each minute.
export function useMinuteClock(): number {
  return useSyncExternalStore(subscribePageMinute, read, read);
}
