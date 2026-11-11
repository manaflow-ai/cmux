// The folded hat's header holds still while its work changes under it (Leo, 2026-11-11, on his
// NIGHTLY's end of a turn: "the animation system is so borked and unintegrated"). With 60 background
// commands, each new one took the header's lead: its name, its marks and the "+N more" swapped on
// every start, and its clock, the earliest start among what still ran, went back when that one ended
// ("glaeda-gh wait +60 more 1h 40m 4s", then "+54 more 1h 27m 28s", then "+61 more 1h 40m 20s").
//
// One rule: the header leads with the longest-running item, which stays the lead until it ends, and
// its clock is the time since the run began, the earliest start seen since the hat last had nothing
// running. A new item never moves the lead or the marks, and an item ending never moves the clock
// back; only the count changes. O(items) per change of the list, never per tick.
import { itemStart, type TrayItem } from "./runningTray";

/// The items longest-running first: by start, oldest first; an item with no start time last, in its
/// list order. A parent and its nested subagents keep their order (the list's own grouping).
export function longestRunningFirst(items: readonly TrayItem[]): TrayItem[] {
  return items
    .map((item, index) => ({ item, index, start: itemStart(item) ?? Number.POSITIVE_INFINITY }))
    .sort((a, b) => a.start - b.start || a.index - b.index)
    .map(({ item }) => item);
}

/// The run's clock start: the earliest start seen since the hat last had nothing running. `before`
/// is the last value; with nothing running the run is over (undefined), and the next starts afresh.
export function runSince(before: number | undefined, items: readonly TrayItem[]): number | undefined {
  if (items.length === 0) return undefined;
  let since = before ?? Number.POSITIVE_INFINITY;
  for (const item of items) {
    const start = itemStart(item);
    if (start !== undefined && start < since) since = start;
  }
  return Number.isFinite(since) ? since : undefined;
}
