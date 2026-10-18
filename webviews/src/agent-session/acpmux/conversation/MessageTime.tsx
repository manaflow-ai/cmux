import { usePaneLanguage } from "../i18n";

/// A prompt's own send time, out of the row's flow (Lucas 2026-10-18).
export function MessageTime({ at }: { at: number }) {
  const locale = usePaneLanguage();
  if (!Number.isFinite(at) || at <= 0) return null;
  const date = new Date(at);
  const today = date.toDateString() === new Date().toDateString();
  return (
    <time
      className="cv-user__time"
      dateTime={date.toISOString()}
      aria-label={new Intl.DateTimeFormat(locale, { dateStyle: "full", timeStyle: "long" }).format(date)}
      data-find-skip
    >
      {new Intl.DateTimeFormat(locale, {
        hour: "numeric",
        minute: "2-digit",
        ...(!today && { year: "numeric", month: "short", day: "numeric" }),
      }).format(date)}
    </time>
  );
}
