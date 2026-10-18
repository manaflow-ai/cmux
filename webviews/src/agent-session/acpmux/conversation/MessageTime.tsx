/// A prompt's own send time, beside its actions (Lucas 2026-10-18). The system's locale, as the turn
/// footer's time (TurnRows.tsx), so both read on the same clock (24-hour or not).
export function MessageTime({ at }: { at: number }) {
  if (!Number.isFinite(at) || at <= 0) return null;
  const date = new Date(at);
  const today = date.toDateString() === new Date().toDateString();
  return (
    <time
      className="cv-user__time"
      dateTime={date.toISOString()}
      aria-label={new Intl.DateTimeFormat(undefined, { dateStyle: "full", timeStyle: "long" }).format(date)}
      data-find-skip
    >
      {new Intl.DateTimeFormat(undefined, {
        hour: "numeric",
        minute: "2-digit",
        ...(!today && { year: "numeric", month: "short", day: "numeric" }),
      }).format(date)}
    </time>
  );
}
