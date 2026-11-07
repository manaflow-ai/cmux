// Time labels and receipts' times as the Swift transcript writes them (MessagesLab `Format`):
// the day is Today, Yesterday, the weekday within a week, "MMM d" within 300 days, else "MMM d, yyyy";
// the time is "h:mm a" in the app's language. Formatters are made once per language.
import type { Strings } from "../../shared/i18n";

const formatters = new Map<
  string,
  { time: Intl.DateTimeFormat; weekday: Intl.DateTimeFormat; monthDay: Intl.DateTimeFormat; full: Intl.DateTimeFormat }
>();

function formattersFor(language: string) {
  let entry = formatters.get(language);
  if (!entry) {
    entry = {
      time: new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" }),
      weekday: new Intl.DateTimeFormat(language, { weekday: "long" }),
      monthDay: new Intl.DateTimeFormat(language, { month: "short", day: "numeric" }),
      full: new Intl.DateTimeFormat(language, { month: "short", day: "numeric", year: "numeric" }),
    };
    formatters.set(language, entry);
  }
  return entry;
}

const startOfDay = (at: number) => {
  const date = new Date(at);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
};

/** Whole calendar days from `at` to `now` (local time; a DST day still counts as one). */
export function daysBetween(at: number, now: number): number {
  return Math.round((startOfDay(now) - startOfDay(at)) / 86_400_000);
}

export function formatDay(at: number, now: number, strings: Strings): string {
  const days = daysBetween(at, now);
  if (days === 0) return strings.t("separator.today");
  if (days === 1) return strings.t("separator.yesterday");
  const f = formattersFor(strings.language);
  if (days > 1 && days < 7) return f.weekday.format(at);
  return days < 300 ? f.monthDay.format(at) : f.full.format(at);
}

export function formatTime(at: number, strings: Strings): string {
  return formattersFor(strings.language).time.format(at);
}
