// Formatter construction is expensive and these run for several cells of every
// visible row in the virtualized session list, so cache instances per locale.
const numberFormatCache = new Map<string, Intl.NumberFormat>();
const dateTimeFormatCache = new Map<string, Intl.DateTimeFormat>();
const relativeTimeFormatCache = new Map<string, Intl.RelativeTimeFormat>();

function cachedNumberFormat(locale: string, maximumFractionDigits: number): Intl.NumberFormat {
  const key = `${locale}|${maximumFractionDigits}`;
  let format = numberFormatCache.get(key);
  if (!format) {
    format = new Intl.NumberFormat(locale, { maximumFractionDigits });
    numberFormatCache.set(key, format);
  }
  return format;
}

function cachedDateTimeFormat(locale: string): Intl.DateTimeFormat {
  let format = dateTimeFormatCache.get(locale);
  if (!format) {
    format = new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" });
    dateTimeFormatCache.set(locale, format);
  }
  return format;
}

function cachedRelativeTimeFormat(locale: string): Intl.RelativeTimeFormat {
  let format = relativeTimeFormatCache.get(locale);
  if (!format) {
    format = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
    relativeTimeFormatCache.set(locale, format);
  }
  return format;
}

export function formatBytes(bytes: number | null | undefined, locale: string): string {
  if (bytes == null) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  return `${cachedNumberFormat(locale, unitIndex === 0 ? 0 : 1).format(value)} ${units[unitIndex]}`;
}

export function formatDate(value: Date | string, locale: string): string {
  const date = typeof value === "string" ? new Date(value) : value;
  return cachedDateTimeFormat(locale).format(date);
}

export function formatRelativeTime(
  value: Date | string,
  locale: string,
  now: Date = new Date(),
): string {
  const date = typeof value === "string" ? new Date(value) : value;
  const seconds = Math.round((date.getTime() - now.getTime()) / 1000);
  const divisions = [
    { amount: 60, unit: "second" },
    { amount: 60, unit: "minute" },
    { amount: 24, unit: "hour" },
    { amount: 7, unit: "day" },
    { amount: 4.34524, unit: "week" },
    { amount: 12, unit: "month" },
    { amount: Number.POSITIVE_INFINITY, unit: "year" },
  ] as const;

  let duration = seconds;
  for (const division of divisions) {
    if (Math.abs(duration) < division.amount) {
      return cachedRelativeTimeFormat(locale).format(Math.round(duration), division.unit);
    }
    duration /= division.amount;
  }
  return formatDate(date, locale);
}

export function truncateMiddle(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value;
  const keep = Math.max(1, Math.floor((maxLength - 3) / 2));
  return `${value.slice(0, keep)}...${value.slice(-keep)}`;
}

export function pathBasename(path: string | null | undefined): string {
  if (!path) return "";
  const parts = path.split(/[\\/]/).filter(Boolean);
  return parts.at(-1) ?? path;
}
