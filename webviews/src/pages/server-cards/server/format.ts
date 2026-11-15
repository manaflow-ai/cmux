// Dates, sizes and regions in the page's language. Absolute times: nothing on the server surfaces
// counts down, so nothing needs a timer.

const sameDay = (a: Date, b: Date) =>
  a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();

/** Today's times as the time alone; other days with a short month and day. */
export function formatTime(ms: number, language: string, now: number = Date.now()): string {
  const date = new Date(ms);
  if (sameDay(date, new Date(now))) return new Intl.DateTimeFormat(language, { timeStyle: "short" }).format(date);
  return new Intl.DateTimeFormat(language, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

const UNITS = ["byte", "kilobyte", "megabyte", "gigabyte", "terabyte"] as const;

/** A file size in decimal units (1 KB = 1000 bytes), as Finder shows it. */
export function formatBytes(count: number, language: string): string {
  let value = Math.max(count, 0);
  let unit = 0;
  while (value >= 1000 && unit < UNITS.length - 1) {
    value /= 1000;
    unit++;
  }
  return new Intl.NumberFormat(language, {
    style: "unit",
    unit: UNITS[unit],
    unitDisplay: "short",
    maximumFractionDigits: unit < 2 ? 0 : 1,
  }).format(value);
}

/** A region code's name in the page's language, or the code itself. */
export function regionName(code: string, language: string): string {
  try {
    return new Intl.DisplayNames([language], { type: "region" }).of(code) ?? code;
  } catch {
    return code;
  }
}

const STEPS: [Intl.RelativeTimeFormatUnit, number][] = [
  ["second", 60],
  ["minute", 60],
  ["hour", 24],
  ["day", 7],
  ["week", 4.35],
  ["month", 12],
  ["year", Infinity],
];

/** "5 minutes ago" in the page's language. */
export function formatRelative(ms: number, language: string, now: number = Date.now()): string {
  let value = (ms - now) / 1000;
  for (const [unit, size] of STEPS) {
    if (Math.abs(value) < size)
      return new Intl.RelativeTimeFormat(language, { numeric: "auto" }).format(Math.round(value), unit);
    value /= size;
  }
  return "";
}
