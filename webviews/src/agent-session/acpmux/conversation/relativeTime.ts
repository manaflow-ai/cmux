// A message's age as Claude Code desktop writes it under a prompt: "now", "5 minutes ago",
// "1 hour ago", "yesterday", then the date past a week. Intl words it in the pane's language.

/// `at`'s age at `now`, in `locale`.
export function relativeTime(at: number, now: number, locale?: string): string {
  // A time past `now` is a prompt the minute clock (clock.ts) has not caught up with, or another
  // computer's clock running ahead: it reads "now".
  const seconds = Math.max(0, now - at) / 1000;
  const words = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
  // Each unit rounds, and a count that rounds up to the next unit reads in it ("1 hour ago", never
  // "60 minutes ago").
  const minutes = Math.round(seconds / 60);
  if (minutes < 1) return words.format(0, "second");
  if (minutes < 60) return words.format(-minutes, "minute");
  const hours = Math.round(seconds / 3600);
  if (hours < 24) return words.format(-hours, "hour");
  const days = Math.round(seconds / 86_400);
  if (days < 7) return words.format(-days, "day");
  return new Intl.DateTimeFormat(locale, { month: "short", day: "numeric" }).format(at);
}
