// A cron schedule (Claude's CronCreate `cron`, five fields in the machine's local time) in words:
// "17 * * * *" reads "hourly at :17", "*/5 * * * *" "every 5 min", "0 9 * * 1-5" "weekdays at
// 9:00 AM". A shape it does not know stays the raw string. Leo, 2026-11-03: "one shows a raw cron
// string '17 * * * *' instead of 'hourly at :17'". `nextCronFire` is when a schedule next runs,
// for a one-shot job's end (session-info/scheduled.ts).
import type { PaneLanguage, Translate } from "../i18n";

type Fields = { minute: string; hour: string; day: string; month: string; weekday: string };

function fieldsOf(expression: string): Fields | undefined {
  const parts = expression.trim().split(/\s+/);
  if (parts.length !== 5) return undefined;
  const [minute, hour, day, month, weekday] = parts as [string, string, string, string, string];
  return { minute, hour, day, month, weekday };
}

/// A plain number in `min...max`, or undefined.
function single(field: string, min: number, max: number): number | undefined {
  if (!/^\d{1,2}$/.test(field)) return undefined;
  const value = Number(field);
  return value >= min && value <= max ? value : undefined;
}

/// `*/N` with N in `2...max`, or undefined.
function step(field: string, max: number): number | undefined {
  const match = /^\*\/(\d{1,2})$/.exec(field);
  if (!match) return undefined;
  const value = Number(match[1]);
  return value >= 2 && value <= max ? value : undefined;
}

const pad = (value: number) => String(value).padStart(2, "0");

/// `hour:minute` as the pane's language writes a time of day ("9:00 AM", "09:00").
function timeOfDay(hour: number, minute: number, language: PaneLanguage): string {
  try {
    return new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" }).format(
      new Date(2026, 0, 5, hour, minute),
    );
  } catch {
    return `${hour}:${pad(minute)}`;
  }
}

/// Weekday `day` (0 or 7 Sunday ... 6 Saturday) as the pane's language names it.
function weekdayName(day: number, language: PaneLanguage): string {
  // 2026-01-04 is a Sunday.
  const date = new Date(2026, 0, 4 + (day % 7));
  try {
    return new Intl.DateTimeFormat(language, { weekday: "long" }).format(date);
  } catch {
    return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][day % 7]!;
  }
}

function monthDay(month: number, day: number, language: PaneLanguage): string {
  const date = new Date(2026, month - 1, day);
  try {
    return new Intl.DateTimeFormat(language, { month: "short", day: "numeric" }).format(date);
  } catch {
    return `${month}/${day}`;
  }
}

/// `expression` in words, or the expression itself for a shape it does not know.
export function cronWords(expression: string, t: Translate, language: PaneLanguage = "en"): string {
  const raw = expression.trim();
  const fields = fieldsOf(raw);
  if (!fields) return raw;
  const { minute, hour, day, month, weekday } = fields;
  const everyDay = day === "*" && month === "*";
  // Every minute, every N minutes.
  if (hour === "*" && everyDay && weekday === "*") {
    if (minute === "*") return t("cron.everyMinute");
    const n = step(minute, 59);
    if (n !== undefined) return t("cron.everyMinutes", { n });
  }
  const m = single(minute, 0, 59);
  if (m === undefined) return raw;
  // Hourly at :MM, every N hours at :MM.
  if (everyDay && weekday === "*") {
    if (hour === "*") return t("cron.hourly", { minute: pad(m) });
    const n = step(hour, 23);
    if (n !== undefined) return t("cron.everyHours", { n, minute: pad(m) });
  }
  const h = single(hour, 0, 23);
  if (h === undefined) return raw;
  const time = timeOfDay(h, m, language);
  if (everyDay) {
    if (weekday === "*") return t("cron.daily", { time });
    if (weekday === "1-5") return t("cron.weekdays", { time });
    const d = single(weekday, 0, 7);
    if (d !== undefined) return t("cron.weekly", { day: weekdayName(d, language), time });
    return raw;
  }
  if (weekday !== "*") return raw;
  const dayOfMonth = single(day, 1, 31);
  if (dayOfMonth === undefined) return raw;
  if (month === "*") return t("cron.monthly", { day: dayOfMonth, time });
  const monthOfYear = single(month, 1, 12);
  if (monthOfYear === undefined) return raw;
  return t("cron.onDate", { date: monthDay(monthOfYear, dayOfMonth, language), time });
}

/// The values a field allows in `min...max`: `*`, `N`, `a-b`, `*/n`, `a-b/n` and comma lists. Undefined
/// for anything else (names, `L`, `?`).
function allowed(field: string, min: number, max: number): Set<number> | undefined {
  const values = new Set<number>();
  for (const part of field.split(",")) {
    const match = /^(\*|\d{1,2}(?:-\d{1,2})?)(?:\/(\d{1,2}))?$/.exec(part);
    if (!match) return undefined;
    const [, range, by] = match;
    const every = by === undefined ? 1 : Number(by);
    if (every < 1) return undefined;
    let low = min;
    let high = max;
    if (range !== "*") {
      const [a, b] = range!.split("-").map(Number) as [number, number | undefined];
      low = a;
      high = b ?? (by === undefined ? a : max);
    }
    if (low < min || high > max || low > high) return undefined;
    for (let value = low; value <= high; value += every) values.add(value);
  }
  return values;
}

/// The first local minute strictly after `after` (epoch ms) that `expression` matches, within about
/// a year; undefined for a schedule it cannot read or that never matches in that time. Day of month
/// and weekday combine as cron does: either matches when both are restricted (neither starts with `*`).
export function nextCronFire(expression: string, after: number): number | undefined {
  const fields = fieldsOf(expression);
  if (!fields) return undefined;
  const minutes = allowed(fields.minute, 0, 59);
  const hours = allowed(fields.hour, 0, 23);
  const days = allowed(fields.day, 1, 31);
  const months = allowed(fields.month, 1, 12);
  const weekdays = allowed(fields.weekday, 0, 7);
  if (!minutes || !hours || !days || !months || !weekdays) return undefined;
  if (weekdays.has(7)) weekdays.add(0);
  // As cron does: a field that starts with `*` (`*`, `*/2`) does not restrict, so it ANDs.
  const dayRestricted = !fields.day.startsWith("*");
  const weekdayRestricted = !fields.weekday.startsWith("*");
  const date = new Date(after);
  date.setSeconds(0, 0);
  date.setMinutes(date.getMinutes() + 1);
  const limit = after + 400 * 24 * 60 * 60 * 1000;
  while (date.getTime() <= limit) {
    if (!months.has(date.getMonth() + 1)) {
      date.setMonth(date.getMonth() + 1, 1);
      date.setHours(0, 0, 0, 0);
      continue;
    }
    const dayMatch = days.has(date.getDate());
    const weekdayMatch = weekdays.has(date.getDay());
    const dayOk = dayRestricted && weekdayRestricted ? dayMatch || weekdayMatch : dayMatch && weekdayMatch;
    if (!dayOk) {
      date.setDate(date.getDate() + 1);
      date.setHours(0, 0, 0, 0);
      continue;
    }
    if (!hours.has(date.getHours())) {
      date.setHours(date.getHours() + 1, 0, 0, 0);
      continue;
    }
    if (!minutes.has(date.getMinutes())) {
      date.setMinutes(date.getMinutes() + 1, 0, 0);
      continue;
    }
    return date.getTime();
  }
  return undefined;
}
