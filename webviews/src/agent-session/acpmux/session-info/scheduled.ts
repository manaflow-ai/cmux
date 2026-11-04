// Whether a wakeup or cron job the agent scheduled (sessionSummary `scheduled`) is still ahead of
// it, and how it ended once it is not: a wakeup whose time has passed is done, a one-shot cron job
// whose time has passed is done, a recurring one past Claude Code's 7-day limit has expired, one
// a CronDelete removed is cancelled, and a call that failed scheduled nothing. Ended ones fold
// into Background tasks' "N finished" (TasksSection.tsx, native/tasks.ts) with that state and
// time. Leo, 2026-11-03: "expired waits like 'Wake at ~03:37Z' stay listed forever ... Fold expired
// waits into done".
//
// The clock only moves when it must: `useScheduledClock` sets one timer for the earliest moment an
// item ends (`nextScheduledChange`), never a per-second poll, and clears it on unmount or when the
// items change.
import { useContext, useEffect, useState } from "react";
import { SubagentClockContext } from "../subagents/SubagentGroup";
import type { SummaryWakeup } from "../summary/sessionSummary";
import { formatDuration } from "../conversation/turns";
import type { PaneLanguage, StringKey, Translate } from "../i18n";
import { cronWords, nextCronFire } from "./cronWords";

/// How long Claude Code keeps a recurring cron job before it expires on its own.
export const RECURRING_CRON_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;

export type ScheduledState = "scheduled" | "done" | "expired" | "cancelled" | "failed";

export type ScheduledStatus = {
  state: ScheduledState;
  /// When it ended (epoch ms, the session's clock), or undefined while it is ahead or unknown.
  endedAt?: number;
  /// When it runs next, while it is ahead and that is known.
  dueAt?: number;
};

/// When `item` ends on its own, with no later call: a wakeup at its time, a one-shot cron job at
/// its first run, a recurring one at its 7-day limit. Undefined when its start is not known.
function endsAt(item: SummaryWakeup): number | undefined {
  if (item.kind === "wakeup") return item.dueAt;
  if (item.startedAt === undefined) return undefined;
  if (item.recurring === false) return item.cron ? nextCronFire(item.cron, item.startedAt) : undefined;
  return item.startedAt + RECURRING_CRON_LIFETIME_MS;
}

/// Where `item` stands at `now`.
export function scheduledStatus(item: SummaryWakeup, now: number): ScheduledStatus {
  if (item.failed) return { state: "failed", ...(item.startedAt !== undefined ? { endedAt: item.startedAt } : {}) };
  const ends = endsAt(item);
  if (item.cancelledAt !== undefined && (ends === undefined || item.cancelledAt < ends))
    return { state: "cancelled", endedAt: item.cancelledAt };
  if (ends !== undefined && now >= ends)
    return { state: item.kind === "cron" && item.recurring !== false ? "expired" : "done", endedAt: ends };
  const dueAt = item.kind === "wakeup" ? item.dueAt : item.cron ? nextCronFire(item.cron, now) : undefined;
  return { state: "scheduled", ...(dueAt !== undefined ? { dueAt } : {}) };
}

export type ScheduledEntry = { item: SummaryWakeup; status: ScheduledStatus };

/// The items still ahead, in the order scheduled, and the ended ones, latest first.
export function splitScheduled(
  items: readonly SummaryWakeup[],
  now: number,
): { active: ScheduledEntry[]; finished: ScheduledEntry[] } {
  const entries = items.map((item) => ({ item, status: scheduledStatus(item, now) }));
  return {
    active: entries.filter((entry) => entry.status.state === "scheduled"),
    finished: entries
      .filter((entry) => entry.status.state !== "scheduled")
      .sort((a, b) => (b.status.endedAt ?? -Infinity) - (a.status.endedAt ?? -Infinity)),
  };
}

/// The earliest moment after `now` that an item still ahead ends, or undefined when none will.
export function nextScheduledChange(items: readonly SummaryWakeup[], now: number): number | undefined {
  let next: number | undefined;
  for (const item of items) {
    if (scheduledStatus(item, now).state !== "scheduled") continue;
    const ends = endsAt(item);
    if (ends !== undefined && ends > now && (next === undefined || ends < next)) next = ends;
  }
  return next;
}

/// The longest wait setTimeout takes (about 24.8 days); a later end sets a new timer when it fires.
const MAX_TIMEOUT_MS = 2 ** 31 - 1;

/// How long the clock's timer waits for `next` at `now`: a millisecond past it, so the item has
/// ended when it fires, and never past the longest wait setTimeout takes (a longer one fires at
/// once, which would re-arm in a loop; review of #33314).
export function scheduledTimerDelay(next: number, now: number): number {
  return Math.min(MAX_TIMEOUT_MS, Math.max(0, next - now) + 1);
}

/// The session's clock (SubagentClockContext) as of the latest moment one of `items` ended: it moves
/// once, when the earliest item still ahead reaches its end, by one timer that is cleared on unmount
/// and replaced when the items change. No timer while nothing is ahead.
export function useScheduledClock(items: readonly SummaryWakeup[], clock: () => number = Date.now): number {
  const offset = useContext(SubagentClockContext);
  const [now, setNow] = useState(() => clock() - offset);
  const next = nextScheduledChange(items, now);
  useEffect(() => {
    if (next === undefined) return;
    const timer = setTimeout(() => setNow(clock() - offset), scheduledTimerDelay(next, clock() - offset));
    return () => clearTimeout(timer);
    // `now` too: a wait capped at the longest timeout fires before `next`, and re-arms from there.
  }, [next, now, offset, clock]);
  return now;
}

/// What a scheduled row says on its right: while ahead, a cron job's schedule in words and a
/// wakeup's time of day; once ended, its state and, for one that ran, how long it waited ("Done ·
/// 4m", "Expired", "Cancelled", "Failed").
export function scheduledTrailing(t: Translate, language: PaneLanguage, entry: ScheduledEntry): string | undefined {
  const { item, status } = entry;
  if (status.state === "scheduled") {
    if (item.cron) return cronWords(item.cron, t, language);
    return status.dueAt !== undefined ? timeOfDayAt(status.dueAt, language) : undefined;
  }
  const word = t(SCHEDULED_STATE[status.state]);
  if (status.state !== "done" || status.endedAt === undefined || item.startedAt === undefined) return word;
  return `${word} · ${formatDuration(Math.max(0, status.endedAt - item.startedAt))}`;
}

const SCHEDULED_STATE: Record<Exclude<ScheduledState, "scheduled">, StringKey> = {
  done: "subagents.state.completed",
  expired: "bgTask.state.expired",
  cancelled: "subagents.state.cancelled",
  failed: "bgTask.state.failed",
};

function timeOfDayAt(at: number, language: PaneLanguage): string {
  try {
    return new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" }).format(new Date(at));
  } catch {
    const date = new Date(at);
    return `${date.getHours()}:${String(date.getMinutes()).padStart(2, "0")}`;
  }
}
