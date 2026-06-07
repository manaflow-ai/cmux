import type { AgentSessionRateLimitRow } from "./types";

export type NormalizedRateLimitRow = AgentSessionRateLimitRow & {
  remainingPercent: number;
  usedPercent: number;
  windowDurationMins?: number;
};

export type RateLimitWindowLabels = {
  weekly: string;
  monthly: string;
  daysFormat: string;
  hoursFormat: string;
  minutesFormat: string;
};

export function normalizeRateLimitRow(row: AgentSessionRateLimitRow): NormalizedRateLimitRow {
  const usedPercentValue = row.usedPercent;
  const remainingPercentValue = row.remainingPercent;
  const usedPercent = usedPercentValue != null && Number.isFinite(usedPercentValue)
    ? clampPercent(usedPercentValue)
    : clampPercent(100 - (remainingPercentValue ?? 0));
  const remainingPercent = remainingPercentValue != null && Number.isFinite(remainingPercentValue)
    ? clampPercent(remainingPercentValue)
    : clampPercent(100 - usedPercent);
  return {
    ...row,
    remainingPercent,
    usedPercent,
    windowDurationMins: Number.isFinite(row.windowDurationMins) ? row.windowDurationMins : undefined,
  };
}

export function activeRateLimitRow(rows: AgentSessionRateLimitRow[]): NormalizedRateLimitRow | null {
  const normalizedRows = rows.map(normalizeRateLimitRow);
  if (normalizedRows.length === 0) {
    return null;
  }
  return normalizedRows.reduce((current, candidate) => {
    if (candidate.usedPercent > current.usedPercent) {
      return candidate;
    }
    if (candidate.usedPercent < current.usedPercent) {
      return current;
    }
    return (candidate.windowDurationMins ?? -Infinity) > (current.windowDurationMins ?? -Infinity)
      ? candidate
      : current;
  });
}

export function formatRateLimitPercent(value: number): string {
  if (!Number.isFinite(value)) {
    return "100%";
  }
  return `${Math.round(clampPercent(value))}%`;
}

export function formatRateLimitReset(resetsAt: number | undefined, now = new Date()): string | null {
  if (resetsAt == null || !Number.isFinite(resetsAt)) {
    return null;
  }
  const date = new Date(resetsAt * 1000);
  if (!Number.isFinite(date.getTime())) {
    return null;
  }
  const secondsUntilReset = Math.floor((date.getTime() - now.getTime()) / 1000);
  if (secondsUntilReset > 0 && secondsUntilReset < 60 * 60) {
    return new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(date);
  }
  if (isSameLocalDay(date, now)) {
    return new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(date);
  }
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(date);
}

export function formatRateLimitWindow(
  minutes: number | undefined,
  fallback: string,
  labels?: RateLimitWindowLabels,
): string {
  if (minutes == null || !Number.isFinite(minutes) || minutes <= 0) {
    return fallback;
  }
  const rounded = Math.round(minutes);
  if (withinRatio(minutes, 30 * 24 * 60)) {
    return labels?.monthly ?? fallback;
  }
  if (withinRatio(minutes, 7 * 24 * 60)) {
    return labels?.weekly ?? fallback;
  }
  if (rounded >= 24 * 60) {
    return formatCompactDurationLabel(labels?.daysFormat, Math.ceil(rounded / (24 * 60)), fallback);
  }
  if (rounded >= 60) {
    return formatCompactDurationLabel(labels?.hoursFormat, Math.ceil(rounded / 60), fallback);
  }
  return formatCompactDurationLabel(labels?.minutesFormat, Math.max(1, Math.ceil(rounded)), fallback);
}

function clampPercent(value: number): number {
  if (!Number.isFinite(value)) {
    return 100;
  }
  return Math.min(Math.max(value, 0), 100);
}

function withinRatio(value: number, target: number): boolean {
  return value >= target * 0.95 && value <= target * 1.05;
}

function isSameLocalDay(date: Date, other: Date): boolean {
  return (
    date.getFullYear() === other.getFullYear() &&
    date.getMonth() === other.getMonth() &&
    date.getDate() === other.getDate()
  );
}

function formatCompactDurationLabel(format: string | undefined, value: number, fallback: string): string {
  const formattedValue = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(value);
  if (format == null || format.length === 0) {
    return fallback;
  }
  return format
    .replaceAll("%@", formattedValue)
    .replaceAll("%d", formattedValue)
    .replaceAll("{value}", formattedValue);
}
