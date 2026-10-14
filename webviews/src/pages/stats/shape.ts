// Pure shaping for the Stats page: durations and counts in the person's language (Intl, so no
// plural strings), the heatmap grid and the hour bars. The page and its tests share these.
import type { DayStats } from "./types";

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

/** `5 days` in the person's language. */
export function formatDays(days: number, language: string): string {
  return new Intl.NumberFormat(language, { style: "unit", unit: "day", unitDisplay: "long" }).format(days);
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
  const max = Math.max(0, ...days.map((entry) => entry.workingMs));
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
