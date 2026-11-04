// A message's age and its exact time, as Claude Code desktop writes them in a message's hover row:
// "just now" under a minute, then "5 minutes ago", "1 hour ago", "yesterday", "3 days ago",
// "last week", "2 months ago", "last year" (it never switches to a date there), and on hover
// "Oct 20, 2026, 10:16 PM". Intl words both in the pane's language.
import { hasTimestamp } from "./timestamps";

/// Claude's units, largest first, in seconds: the age reads in the largest one it has reached.
const UNITS: readonly (readonly [Intl.RelativeTimeFormatUnit, number])[] = [
  ["year", 31_536_000],
  ["month", 2_592_000],
  ["week", 604_800],
  ["day", 86_400],
  ["hour", 3_600],
  ["minute", 60],
];

// Newly mounted messages share the pane's language. Keep one formatter, not one per message
// or an unbounded map of locale strings. Default-locale fallbacks stay live and uncached.
let lastWords: { locale: string; formatter: Intl.RelativeTimeFormat; englishNow: boolean } | undefined;
function relativeWords(locale?: string) {
  if (locale !== undefined && lastWords?.locale === locale) return lastWords;
  const formatter = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
  const words = { formatter, englishNow: formatter.resolvedOptions().locale.toLowerCase().startsWith("en") };
  if (locale !== undefined && Intl.RelativeTimeFormat.supportedLocalesOf(locale).length)
    lastWords = { locale, ...words };
  return words;
}

/// `at`'s age at `now`, in `locale`.
export function relativeTime(at: number, now: number, locale?: string): string {
  // A time past `now` is a prompt the minute clock (clock.ts) has not caught up with, or another
  // computer's clock running ahead: it reads as just sent, never "in 1 minute".
  const seconds = Math.round(Math.min(0, at - now) / 1000);
  const age = -seconds;
  const words = relativeWords(locale);
  if (age < 60) {
    // English says "just now" (Claude's words); other languages their own word for now.
    // l10n-allow: English only by design (Claude's wording); every other language gets Intl's own word.
    return words.englishNow ? "just now" : words.formatter.format(0, "second");
  }
  const [unit, size] = UNITS.find(([, length]) => age >= length) ?? ["minute", 60];
  // The count rounds within its unit, as Claude's does (Math.round on the negative count: 90
  // minutes is "1 hour ago", 36 hours "yesterday"); "auto" says "yesterday", "last week".
  return words.formatter.format(Math.round(seconds / size), unit);
}

/// Claude's exact time for a message: "Oct 20, 2026, 10:16 PM" in en-US, the same fields in
/// `locale`'s order and words ("20. Okt. 2026, 22:16" in German).
const EXACT: Intl.DateTimeFormatOptions = {
  year: "numeric",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
};

/// `at` as Claude's hover tooltip writes it, in `locale`.
export function exactTime(at: number, locale?: string): string {
  try {
    return new Date(at).toLocaleString(locale, EXACT);
  } catch {
    // A language tag Intl does not take: the system's.
    return new Date(at).toLocaleString(undefined, EXACT);
  }
}

/// A reply's time in its action row, as ChatGPT writes it there on hover: "Oct 18, 5:41 AM", the
/// year added only when it is not `now`'s ("Oct 18, 2025, 5:41 AM"), in `locale`'s order and words.
export function replyTime(at: number, now: number, locale?: string): string {
  const sameYear = new Date(at).getFullYear() === new Date(now).getFullYear();
  const fields: Intl.DateTimeFormatOptions = sameYear ? { ...EXACT, year: undefined } : EXACT;
  try {
    return new Date(at).toLocaleString(locale, fields);
  } catch {
    return new Date(at).toLocaleString(undefined, fields);
  }
}

/// The reply menu's quiet header, as ChatGPT writes it: today's or yesterday's time,
/// otherwise the exact date. Format on opening only; no clock or idle work is needed.
export function replyMenuTime(at: number, now: number, locale?: string): string {
  if (!hasTimestamp(at)) return "";
  const date = new Date(at);
  const today = new Date(now);
  const day = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
  const current = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
  const delta = Math.round((day - current) / 86_400_000);
  if (delta !== 0 && delta !== -1) return exactTime(at, locale);
  try {
    const relative = new Intl.RelativeTimeFormat(locale, { numeric: "auto" }).format(delta, "day");
    const label = relative.charAt(0).toLocaleUpperCase(locale) + relative.slice(1);
    return `${label}, ${new Intl.DateTimeFormat(locale, { hour: "numeric", minute: "2-digit" }).format(date)}`;
  } catch {
    return exactTime(at, locale);
  }
}

/** First shared wall-clock minute where relativeTime's unit or rounded count changes. */
export function nextRelativeTime(at: number, now: number): number {
  if (!Number.isFinite(at)) return Infinity;
  const age = -Math.round(Math.min(0, at - now) / 1000);
  const unitIndex = UNITS.findIndex(([, size]) => age >= size);
  const size = unitIndex < 0 ? 60 : UNITS[unitIndex][1];
  const count = -Math.round(-age / size);
  const nextCount = unitIndex < 0 ? 60 : Math.floor((count + 0.5) * size) + 1;
  const nextUnit = unitIndex > 0 ? UNITS[unitIndex - 1][1] : Infinity;
  // relativeTime first rounds negative seconds, then the negative unit count. Ties round toward
  // zero, so the new second starts one millisecond after its half-second boundary.
  const change = at + (Math.min(nextCount, nextUnit) - 0.5) * 1000 + 1;
  return Math.max(now + 60_000, Math.ceil(change / 60_000) * 60_000);
}

/** replyTime's exact timestamp changes only when its year suffix appears or disappears. */
export function nextReplyTime(at: number, now: number): number {
  if (!Number.isFinite(at)) return Infinity;
  const year = new Date(now).getFullYear();
  const target = new Date(at).getFullYear();
  return target < year ? Infinity : new Date(target === year ? year + 1 : target, 0, 1).getTime();
}
