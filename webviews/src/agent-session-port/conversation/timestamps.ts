// Timestamp lines between turns ("Sun, Sep 13 at 7:55 PM", "Yesterday 8:16 PM"), derived
// from turn times as the desktop bundle does it:
//
// - which turns: `timestamps-*.js` `t` (called per turn entry by
//   local-conversation-thread-turn-entries-*.js). Each turn contributes its user message
//   (sent at the turn's start) and, when it has an agent message, its final assistant
//   message (sent when that started). A message gets a line when it is the thread's first
//   user message and is more than an hour old, or when it follows an assistant message by
//   more than an hour (a user message) or ten minutes (an assistant message of a turn
//   without input). A turn shows at most one line, above it. Entries that are not turns
//   reset the adjacency.
// - wording: `timestamps-*.js` `a` and the `conversation.timestampSeparator.recent/older`
//   messages: calendar days before `now` ≤ 1 → "Today"/"Yesterday", ≤ 7 → the weekday,
//   ≤ 365 → "Sun, Sep 13", else "Sep 13, 2025"; time "7:55 PM"; " at " only past 7 days.
import type { Turn } from "./protocol";

const HOUR_MS = 36e5;
const TEN_MIN_MS = 6e5;

type Sent = { role: "user" | "assistant"; sentAtMs: number };

/** The messages one turn contributes, in order (null for an entry that is not a turn). */
export function turnMessages(turn: Turn): Sent[] {
  const out: Sent[] = [];
  if (turn.items.some((i) => i.type === "userMessage"))
    out.push({ role: "user", sentAtMs: turn.startedAt == null ? NaN : turn.startedAt * 1000 });
  if (turn.items.some((i) => i.type === "agentMessage"))
    out.push({ role: "assistant", sentAtMs: turn.finalAnswerStartedAtMs ?? NaN });
  return out;
}

function needsSeparator(current: Sent, previous: Sent | null, firstUser: boolean, nowMs: number) {
  if (!Number.isFinite(current.sentAtMs)) return false;
  if (firstUser && nowMs - current.sentAtMs > HOUR_MS) return true;
  return (
    previous?.role === "assistant" &&
    Number.isFinite(previous.sentAtMs) &&
    current.sentAtMs - previous.sentAtMs > (current.role === "user" ? HOUR_MS : TEN_MIN_MS)
  );
}

/**
 * For each entry (a turn's messages, or null for a non-turn entry), the time its line
 * shows, or null for none.
 */
export function separatorTimes(entries: (Sent[] | null)[], nowMs: number): (number | null)[] {
  let previous: Sent | null = null;
  let seenUser = false;
  return entries.map((messages) => {
    if (messages == null) {
      previous = null;
      seenUser = true;
      return null;
    }
    let at: number | null = null;
    for (const m of messages) {
      if (at == null && needsSeparator(m, previous, m.role === "user" && !seenUser, nowMs))
        at = m.sentAtMs;
      seenUser ||= m.role === "user";
      previous = m;
    }
    return at;
  });
}

export type Clock = {
  /** The moment the screen shows (a capture's time), ms. */
  now: number;
  /** IANA zone the times are shown in (default: the runtime's). */
  timeZone?: string;
  locale?: string;
};

/** Calendar date of `ms` in `timeZone`, as a UTC day number. */
function dayNumber(ms: number, timeZone?: string) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "numeric",
    day: "numeric",
  }).formatToParts(ms);
  const n = (t: string) => Number(parts.find((p) => p.type === t)?.value);
  return Date.UTC(n("year"), n("month") - 1, n("day")) / 864e5;
}

/** The line's day and time, and whether " at " joins them. */
export function formatSeparator(ms: number, clock: Clock) {
  const { timeZone, locale = "en-US" } = clock;
  const days = Math.max(dayNumber(clock.now, timeZone) - dayNumber(ms, timeZone), 0);
  const fmt = (o: Intl.DateTimeFormatOptions) =>
    new Intl.DateTimeFormat(locale, { timeZone, ...o }).format(ms);
  let date: string;
  if (days <= 1) {
    const rel = new Intl.RelativeTimeFormat(locale, { numeric: "auto" }).format(-days, "day");
    date = locale.startsWith("en") ? rel[0]!.toUpperCase() + rel.slice(1) : rel;
  } else if (days <= 7) date = fmt({ weekday: "long" });
  else if (days <= 365) date = fmt({ weekday: "short", month: "short", day: "numeric" });
  else date = fmt({ month: "short", day: "numeric", year: "numeric" });
  return { date, time: fmt({ hour: "numeric", minute: "2-digit" }), includeAt: days > 7 };
}

/** The line as text: "Sun, Sep 13 at 7:55 PM" / "Yesterday 8:16 PM". */
export function separatorText(ms: number, clock: Clock) {
  const { date, time, includeAt } = formatSeparator(ms, clock);
  return includeAt ? `${date} at ${time}` : `${date} ${time}`;
}
