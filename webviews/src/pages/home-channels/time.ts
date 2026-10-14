// Times as the list and thread rows show them, and one display clock. The clock is a narrow hook:
// one timer aligned to the next minute, so "12m" turns into "13m" without a render loop.
import { useEffect, useState } from "react";
import type { Strings } from "../shared/i18n";

export function useClock(): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setTimeout(() => setNow(Date.now()), 60_000 - (Date.now() % 60_000) + 50);
    return () => clearTimeout(timer);
  }, [now]);
  return now;
}

const startOfDay = (at: number) => {
  const d = new Date(at);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
};

/** A list row's time: the clock time today, "Yesterday", the weekday this week, else the date. */
export function shortTime(at: number, now: number, strings: Strings): string {
  if (!at) return "";
  const days = Math.round((startOfDay(now) - startOfDay(at)) / 86_400_000);
  const lang = strings.language;
  if (days <= 0) return new Intl.DateTimeFormat(lang, { hour: "numeric", minute: "2-digit" }).format(at);
  if (days === 1) return strings.t("day.yesterday");
  if (days < 7) return new Intl.DateTimeFormat(lang, { weekday: "short" }).format(at);
  return new Intl.DateTimeFormat(lang, { month: "short", day: "numeric" }).format(at);
}

/** A relative time for thread activity: "now", "12m ago", "3h ago", "2d ago". */
export function relativeTime(at: number, now: number, strings: Strings): string {
  const seconds = Math.round((at - now) / 1000);
  const format = new Intl.RelativeTimeFormat(strings.language, { numeric: "auto", style: "narrow" });
  const abs = Math.abs(seconds);
  if (abs < 60) return format.format(0, "second");
  if (abs < 3600) return format.format(Math.round(seconds / 60), "minute");
  if (abs < 86_400) return format.format(Math.round(seconds / 3600), "hour");
  if (abs < 7 * 86_400) return format.format(Math.round(seconds / 86_400), "day");
  return new Intl.DateTimeFormat(strings.language, { month: "short", day: "numeric" }).format(at);
}
