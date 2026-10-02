// Timestamp lines between turns ("Sun, Sep 13 at 7:55 PM", "Yesterday 8:16 PM"), as Codex
// derives them. After the reference prototype's src/conversation/timestamps.ts, which mirrors the
// desktop bundle (`timestamps-*.js`):
//
// - which turns: each turn contributes its prompt (sent at the turn's start) and, when it has
//   one, its final answer (when that started). A turn gets a line above it when its prompt is
//   the thread's first and over an hour old, or when it comes more than an hour after the
//   previous turn's answer. A day change alone draws no line.
// - wording: calendar days before now ≤ 1 → "Today" / "Yesterday", ≤ 7 → the weekday,
//   ≤ 365 → "Sun, Sep 13", else "Sep 13, 2025"; then the time, joined by " at " only past
//   seven days.

const HOUR_MS = 36e5;

/// One turn's messages: its prompt's time, and its final answer's when it has one.
export type TurnTimes = { promptAt: number; answerAt?: number };

/// For each turn, whether a line shows above it. `loadedFromStart` is false when the first
/// turn here is not the thread's first (rows before it, or older history not paged in).
export function timestampTurns(turns: readonly TurnTimes[], now: number, loadedFromStart: boolean): boolean[] {
  let previousAnswer: number | undefined;
  return turns.map((turn, index) => {
    const first = index === 0 && loadedFromStart && now - turn.promptAt > HOUR_MS;
    const late = previousAnswer !== undefined && turn.promptAt - previousAnswer > HOUR_MS;
    // The previous message is this turn's answer, or its prompt when it has none.
    previousAnswer = turn.answerAt;
    return first || late;
  });
}

export type Clock = { now: number; timeZone?: string; locale?: string };

/// Calendar date of `ms` in `timeZone`, as a UTC day number.
function dayNumber(ms: number, timeZone?: string) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "numeric",
    day: "numeric",
  }).formatToParts(ms);
  const part = (type: string) => Number(parts.find((entry) => entry.type === type)?.value);
  return Date.UTC(part("year"), part("month") - 1, part("day")) / 864e5;
}

/// The line as text: "Sun, Sep 13 at 7:55 PM", "Yesterday 8:16 PM".
export function timestampText(ms: number, clock: Clock): string {
  const { timeZone } = clock;
  const locale = clock.locale ?? new Intl.DateTimeFormat().resolvedOptions().locale;
  const days = Math.max(dayNumber(clock.now, timeZone) - dayNumber(ms, timeZone), 0);
  const format = (options: Intl.DateTimeFormatOptions) =>
    new Intl.DateTimeFormat(locale, { timeZone, ...options }).format(ms);
  let date: string;
  if (days <= 1) {
    const relative = new Intl.RelativeTimeFormat(locale, { numeric: "auto" }).format(-days, "day");
    date = locale.startsWith("en") ? relative[0]!.toUpperCase() + relative.slice(1) : relative;
  } else if (days <= 7) date = format({ weekday: "long" });
  else if (days <= 365) date = format({ weekday: "short", month: "short", day: "numeric" });
  else date = format({ month: "short", day: "numeric", year: "numeric" });
  const time = format({ hour: "numeric", minute: "2-digit" });
  return days > 7 ? `${date} at ${time}` : `${date} ${time}`;
}
