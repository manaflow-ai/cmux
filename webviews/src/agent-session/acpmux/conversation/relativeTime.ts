// A message's age and its exact time, as Claude Code desktop writes them in a message's hover row:
// "just now" under a minute, then "5 minutes ago", "1 hour ago", "yesterday", "3 days ago",
// "last week", "2 months ago", "last year" (it never switches to a date there), and on hover
// "Oct 20, 2026, 10:16 PM". Intl words both in the pane's language.

/// Claude's units, largest first, in seconds: the age reads in the largest one it has reached.
const UNITS: readonly (readonly [Intl.RelativeTimeFormatUnit, number])[] = [
  ["year", 31_536_000],
  ["month", 2_592_000],
  ["week", 604_800],
  ["day", 86_400],
  ["hour", 3_600],
  ["minute", 60],
];

/// `at`'s age at `now`, in `locale`.
export function relativeTime(at: number, now: number, locale?: string): string {
  // A time past `now` is a prompt the minute clock (clock.ts) has not caught up with, or another
  // computer's clock running ahead: it reads as just sent, never "in 1 minute".
  const seconds = Math.round(Math.min(0, at - now) / 1000);
  const age = -seconds;
  if (age < 60) {
    const words = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
    // English says "just now" (Claude's words); other languages their own word for now.
    // l10n-allow: English only by design (Claude's wording); every other language gets Intl's own word.
    return words.resolvedOptions().locale.toLowerCase().startsWith("en") ? "just now" : words.format(0, "second");
  }
  const [unit, size] = UNITS.find(([, length]) => age >= length) ?? ["minute", 60];
  // The count rounds within its unit, as Claude's does (Math.round on the negative count: 90
  // minutes is "1 hour ago", 36 hours "yesterday"); "auto" says "yesterday", "last week".
  return new Intl.RelativeTimeFormat(locale, { numeric: "auto" }).format(Math.round(seconds / size), unit);
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
