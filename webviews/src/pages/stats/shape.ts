// Pure shaping for the Stats page: durations and counts in the person's language (Intl, so no
// plural strings), the heatmap grid and the hour bars. The page and its tests share these.
import type { DayStats, StatsSummary } from "./types";

const DAY_MS = 86_400_000;

export function formatCount(value: number, language: string): string {
  return new Intl.NumberFormat(language).format(value);
}

/** `3h 20m`, `45m`, `0m` in the person's language. */
export function formatDuration(ms: number, language: string): string {
  const minutes = Math.round(ms / 60_000);
  const unit = (value: number, name: "hour" | "minute") =>
    new Intl.NumberFormat(language, { style: "unit", unit: name, unitDisplay: "narrow" }).format(value);
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours === 0) return unit(rest, "minute");
  return rest === 0 ? unit(hours, "hour") : `${unit(hours, "hour")} ${unit(rest, "minute")}`;
}

/** A permission wait: `12s`, `4m 5s` under ten minutes, else as `formatDuration`. */
export function formatWait(ms: number, language: string): string {
  const total = Math.round(ms / 1000);
  if (total >= 600) return formatDuration(ms, language);
  const unit = (value: number, name: "minute" | "second") =>
    new Intl.NumberFormat(language, { style: "unit", unit: name, unitDisplay: "narrow" }).format(value);
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  if (minutes === 0) return unit(seconds, "second");
  return seconds === 0 ? unit(minutes, "minute") : `${unit(minutes, "minute")} ${unit(seconds, "second")}`;
}

/** One row of the Attention section: a wait in ms, a count, or a ratio. */
export type AttentionRow =
  | { key: string; wait: number }
  | { key: string; count: number }
  | { key: string; ratio: number };

/**
 * The Attention rows the summary has data for: waits only once a question was answered, the
 * counts only when acpmux sent them (an older one does not), steers per turn once a turn ran.
 */
export function attentionRows(summary: StatsSummary): AttentionRow[] {
  const rows: AttentionRow[] = [];
  const answered = summary.permissionAnswered;
  if (answered !== undefined && answered > 0) {
    if (summary.permissionWaitMs !== undefined) {
      rows.push({ key: "stats.attention.averageWait", wait: summary.permissionWaitMs / answered });
    }
    if (summary.permissionWaitMaxMs !== undefined) {
      rows.push({ key: "stats.attention.longestWait", wait: summary.permissionWaitMaxMs });
    }
  }
  if (answered !== undefined) rows.push({ key: "stats.attention.answered", count: answered });
  if (summary.permissionUnanswered !== undefined) {
    rows.push({ key: "stats.attention.unanswered", count: summary.permissionUnanswered });
  }
  if (summary.limitErrors !== undefined) rows.push({ key: "stats.attention.limitErrors", count: summary.limitErrors });
  if (summary.turns > 0) rows.push({ key: "stats.attention.steersPerTurn", ratio: summary.steers / summary.turns });
  return rows;
}

/** `5 days` in the person's language. */
export function formatDays(days: number, language: string): string {
  return new Intl.NumberFormat(language, { style: "unit", unit: "day", unitDisplay: "long" }).format(days);
}

/** `Mon, Oct 12` for a `YYYY-MM-DD` day, in the person's language. */
export function formatDay(day: string, language: string): string {
  return new Intl.DateTimeFormat(language, {
    weekday: "short",
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  }).format(new Date(`${day}T00:00:00Z`));
}

/**
 * A day strip's label under `day`: the weekday over a week; over a month the day of the month on
 * today and every seventh day before it (`fromEnd` counts back from today), else none.
 */
export function stripLabel(day: string, fromEnd: number, rangeDays: number, language: string): string {
  if (rangeDays > 7 && fromEnd % 7 !== 0) return "";
  return new Intl.DateTimeFormat(language, {
    ...(rangeDays > 7 ? { day: "numeric" } : { weekday: "short" }),
    timeZone: "UTC",
  }).format(new Date(`${day}T00:00:00Z`));
}

/** `1 PM` or `13 Uhr` for an hour of the day, in the person's language. */
export function formatHour(hour: number, language: string): string {
  return new Intl.DateTimeFormat(language, { hour: "numeric", timeZone: "UTC" }).format(Date.UTC(2026, 0, 1, hour));
}

export interface HeatCell {
  /** `YYYY-MM-DD`; absent for the padding before the first day. */
  day?: string;
  workingMs: number;
  turns: number;
  /** 0 (none) to 4 (busiest). */
  level: number;
}

/** The person's day number for a unix ms instant at their offset. */
const localDay = (at: number, offsetMinutes: number) => Math.floor((at + offsetMinutes * 60_000) / DAY_MS);
const isoDay = (day: number) => new Date(day * DAY_MS).toISOString().slice(0, 10);

/**
 * `rangeDays` cells ending on the person's today, column by column (a column is a week, Sunday
 * first), with empty padding before the first day so weekdays line up in rows.
 */
export function heatmap(days: DayStats[], until: number, offsetMinutes: number, rangeDays: number): HeatCell[] {
  const today = localDay(until, offsetMinutes);
  const first = today - rangeDays + 1;
  const byDay = new Map(days.map((entry) => [entry.day, entry]));
  // Only drawn days set the scale: acpmux's range starts at an instant, so it can carry the
  // partial day before the first drawn one.
  let max = 0;
  for (let day = first; day <= today; day++) max = Math.max(max, byDay.get(isoDay(day))?.workingMs ?? 0);
  // 1970-01-01 was a Thursday: day 0 sits in row 4.
  const padding = (((first + 4) % 7) + 7) % 7;
  const cells: HeatCell[] = Array.from({ length: padding }, () => ({ workingMs: 0, turns: 0, level: 0 }));
  for (let day = first; day <= today; day++) {
    const key = isoDay(day);
    const entry = byDay.get(key);
    const workingMs = entry?.workingMs ?? 0;
    const level = workingMs > 0 && max > 0 ? Math.max(1, Math.ceil((4 * workingMs) / max)) : 0;
    cells.push({ day: key, workingMs, turns: entry?.turns ?? 0, level });
  }
  return cells;
}

/** Each hour's share of the busiest hour, 0 to 1. */
export function hourShares(hours: number[]): number[] {
  const max = Math.max(0, ...hours);
  return Array.from({ length: 24 }, (_, hour) => (max > 0 ? (hours[hour] ?? 0) / max : 0));
}
