import { translate } from "../i18n";
import { textLinks } from "../chips/paths";
import { nextRelativeTime, nextReplyTime, relativeTime } from "./relativeTime";

const DAY_MS = 86_400_000;
const TOKEN_START = "\uE000";
const TOKEN_END = "\uE001";
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})$/;
const CLOCK_TIME = "(?:[01]\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d)?";
const MERIDIEM_TIME = "(?:1[0-2]|0?[1-9])(?::[0-5]\\d)?\\s?(?:[AaPp][Mm]|[AaPp]\\.[Mm]\\.)";
// Any written hour, for a time after a date ("Nov 7 3:22", "2026-11-07 15:04:30.5").
const DATED_TIME = `(?:${MERIDIEM_TIME}|(?:[01]?\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d(?:\\.\\d+)?)?)`;
// Z, UTC or GMT (with an optional offset: "UTC+2"), or an offset: "+02:00", "+0200", "-0800". A
// minus offset with a colon is left out: "10:00-12:00" is a range, not 10:00 at UTC-12.
const ZONE =
  "(?:Z|\\s?(?:UTC|GMT)(?:[+-](?:1[0-4]|0?\\d)(?::?[0-5]\\d)?)?|\\s?\\+(?:1[0-4]|0\\d):?[0-5]\\d|\\s?-(?:1[0-2]|0\\d)[0-5]\\d)";
const MONTH =
  "(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\\.?";
const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const DAY = "(?:3[01]|[12]\\d|0?[1-9])(?:st|nd|rd|th)?";
const DATE_GAP = "(?:,? at |,? )";
// The end of a time: not glued to a word, a path, a decimal or a further ":NN" ("foo.ts:12:30:",
// "12:30::1", "01:23:45:10"); a label colon ("14:40: build started") is fine.
const END = "(?![\\w/%]|:[\\w:]|\\.\\d)";
// In order, each tried first at its position: an ISO timestamp; a date and a time ("2026-11-07
// 15:04", "Nov 7, 2026 at 3:22 PM", "7 Nov 15:04"), in the person's zone unless it names one; a
// 12-hour time ("9pm", "9:30 a.m.", "8:36 AM UTC"); a 24-hour time anywhere in prose ("deploy
// finished 03:22", "15:04+02:00"), with the look-alikes NOT_CLOCK_BEFORE/AFTER name dropped
// after the match; and an hour with no leading zero ("at 3:22") only right after "at", "by",
// "around", "until" or "till", where it is a time and not a ratio, score or verse.
const DETECT = new RegExp(
  [
    "\\b\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(?::\\d{2}(?:\\.\\d+)?)?(?:Z|[+-]\\d{2}:?\\d{2})\\b",
    `\\b\\d{4}-\\d{2}-\\d{2}(?:T|${DATE_GAP})${DATED_TIME}(?:${ZONE})?${END}`,
    `\\b${MONTH} ${DAY}(?:,? \\d{4})?${DATE_GAP}${DATED_TIME}(?:${ZONE})?${END}`,
    `\\b${DAY} ${MONTH}(?: \\d{4})?${DATE_GAP}${DATED_TIME}(?:${ZONE})?${END}`,
    `(?<![\\w.:])${MERIDIEM_TIME}(?:${ZONE})?(?!\\w)`,
    `(?<![\\w.:/+#$@])(?<!(?:^|\\D)-)${CLOCK_TIME}(?:${ZONE})?${END}`,
    `(?<=\\b(?:[Aa]t|[Bb]y|[Aa]round|[Uu]ntil|[Tt]ill) )[1-9]:[0-5]\\d(?:${ZONE})?${END}`,
  ].join("|"),
  "g",
);
// A time with no date or zone is dropped when its neighbors say it is a score, ratio, line:col,
// duration or verse: "won 21:15", "aspect ratio 16:10", "line 12:30", "took 01:23:45",
// "Psalm 23:10", "a 16:10 display", "12:30 left", "at 1:30 into the video".
const BARE_CLOCK = /^\d{1,2}:\d{2}(?::\d{2})?$/;
const NOT_CLOCK_BEFORE =
  /\b(?:won|lost|beat(?:s|en)?|scor(?:e|es|ed)|final|tied|drew|draw|leads?|led|trail(?:s|ed|ing)?|record|odds|ratio|aspect|vs\.?|versus|lines?|ln|col(?:umn)?|row|verses?|chapter|ch\.|took|takes|taking|elapsed|duration|runtime|lasted|lasts|length|uptime|spent|timer|stopwatch|countdown)(?:\s+(?:is|was|of|at|by|to|for))?[\s:=]*$/i;
const VERSE_BOOK =
  /\b(?:Genesis|Exodus|Leviticus|Numbers|Deuteronomy|Joshua|Judges|Ruth|Samuel|Kings|Chronicles|Ezra|Nehemiah|Esther|Job|Psalms?|Proverbs|Ecclesiastes|Isaiah|Jeremiah|Lamentations|Ezekiel|Daniel|Hosea|Joel|Amos|Obadiah|Jonah|Micah|Nahum|Habakkuk|Zephaniah|Haggai|Zechariah|Malachi|Matthew|Mark|Luke|John|Acts|Romans|Corinthians|Galatians|Ephesians|Philippians|Colossians|Thessalonians|Timothy|Titus|Philemon|Hebrews|James|Peter|Jude|Revelation)\s+$/;
const NOT_CLOCK_AFTER =
  /^\s*(?:elapsed|long|left|remaining|into|mark|runtime|duration|aspect|ratio|display|screen|monitor|widescreen|win|loss|victory|defeat|lead|odds|split|in (?:the )?(?:video|clip|recording|track|song)|of (?:video|footage|audio|runtime|playback))\b/i;
// A zone name it cannot place ("15:04 PST", "3:22 ET"): plain rather than read in the wrong zone.
const UNKNOWN_ZONE_AFTER = /^\s?[A-Z]{0,4}T\b/;
const DATED = new RegExp(
  `^(?:(?<isoYear>\\d{4})-(?<isoMonth>\\d{2})-(?<isoDay>\\d{2})(?:T|${DATE_GAP})|(?<month>${MONTH}) (?<monthDay>\\d{1,2})(?:st|nd|rd|th)?(?:,? (?<monthYear>\\d{4}))?${DATE_GAP}|(?<day>\\d{1,2})(?:st|nd|rd|th)? (?<dayMonth>${MONTH})(?: (?<dayYear>\\d{4}))?${DATE_GAP})(?<time>.+)$`,
);
const TIME_OF_DAY = new RegExp(
  `^(?:(?<hour>\\d{1,2}):(?<minute>\\d{2})(?::(?<second>\\d{2})(?<fraction>\\.\\d+)?)?(?:\\s?(?<half>[AaPp])\\.?[Mm]\\.?)?|(?<onlyHour>\\d{1,2})\\s?(?<onlyHalf>[AaPp])\\.?[Mm]\\.?)(?<zone>${ZONE})?$`,
);
const CLOCK_TIMES = new RegExp(CLOCK_TIME, "g");
// A list or range of clock times ("23:55 and 01:28 UTC", "23:55, 00:10 and 01:28 UTC",
// "23:55–01:28 UTC") shares the zone that follows its last time. Found by a linear scan over
// the clock times, not one nested pattern, so long runs of times cannot backtrack.
const CLOCK_TOKEN = new RegExp(`(?<![\\w.:])${CLOCK_TIME}(?![\\d:])`, "g");
const CLOCK_JOIN = /^(?:\s*,\s*(?:(?:and|or)\s+)?|\s+(?:and|or|to|through|until)\s+|\s*[\u2013\u2014-]\s*)$/;
const ISO_SPAN = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?/g;
const CLOCK_ZONE = /^(?: UTC|Z)\b/;
// A clock time right after a date is that date's ("2026-11-07 15:04"), never part of a list.
const DATE_BEFORE = new RegExp(
  `(?:\\d{4}-\\d{2}-\\d{2}|\\b${MONTH} ${DAY}(?:,? \\d{4})?|\\b${DAY} ${MONTH}(?: \\d{4})?)${DATE_GAP}$`,
);
const MAX_JOIN = 12;

/** Spans of two or more clock times joined by commas, "and", "to" or a dash, ending in a zone. */
function clockLists(text: string): Array<{ start: number; end: number; plain?: boolean }> {
  const lists: Array<{ start: number; end: number; plain?: boolean }> = [];
  let run: { start: number; end: number; count: number } | undefined;
  const close = () => {
    if (!run || run.count < 2) return;
    const zone = text.slice(run.end, run.end + 4).match(CLOCK_ZONE);
    if (zone) lists.push({ start: run.start, end: run.end + zone[0].length });
    // "23:55 and 01:28 PST": a zone it cannot place covers every time in the list; all stay plain.
    else if (UNKNOWN_ZONE_AFTER.test(text.slice(run.end, run.end + 6)))
      lists.push({ start: run.start, end: run.end, plain: true });
  };
  // Clock-like pieces of an ISO timestamp ("T05:21", "-07:00") are not clock times themselves.
  const iso = [...text.matchAll(ISO_SPAN)].map((m) => [m.index!, m.index! + m[0].length] as const);
  let isoAt = 0;
  for (const match of text.matchAll(CLOCK_TOKEN)) {
    const start = match.index!;
    while (isoAt < iso.length && iso[isoAt]![1] <= start) isoAt++;
    if (
      (isoAt < iso.length && start >= iso[isoAt]![0]) ||
      DATE_BEFORE.test(text.slice(Math.max(0, start - 32), start))
    ) {
      close();
      run = undefined;
      continue;
    }
    const end = start + match[0].length;
    if (run && start - run.end <= MAX_JOIN && CLOCK_JOIN.test(text.slice(run.end, start))) {
      run.end = end;
      run.count++;
    } else {
      close();
      run = { start, end, count: 1 };
    }
  }
  close();
  return lists;
}
const SHORT_UNITS: readonly (readonly [Intl.RelativeTimeFormatUnit, number])[] = [
  ["day", 86_400_000],
  ["hour", 3_600_000],
  ["minute", 60_000],
];

/** A marked time: its text, when it resolved to, and the message's own time it resolved from. */
export type TimeToken = { source: string; at: number; messageAt?: number };

/** A UTC/ISO time embedded in rendered Markdown, represented without rescanning at render time. */
export function decorateTimes(text: string, messageAt?: number): string {
  let out = "";
  let at = 0;
  while (at < text.length) {
    const tick = text.indexOf("`", at);
    if (tick < 0) break;
    const before = text.slice(at, tick);
    out += decorateProse(before, messageAt);
    const run = text.slice(tick).match(/^`+/)![0];
    const close = text.indexOf(run, tick + run.length);
    if (close < 0) {
      out += text.slice(tick);
      return out;
    }
    const end = close + run.length;
    out += text.slice(tick, end);
    at = end;
  }
  return out + decorateProse(text.slice(at), messageAt);
}

function decorateProse(text: string, messageAt?: number): string {
  if (!text || !/[:ZT]|\d\s?[AaPp]\.?[Mm]/.test(text)) return text;
  const ranges = mergeRanges([
    ...textLinks(text).map((link) => ({ start: link.start, end: link.end })),
    ...markdownDestinations(text),
  ]);
  if (ranges.length) {
    let out = "";
    let from = 0;
    for (const range of ranges) {
      if (range.start < from) continue;
      out += decorateProseSegment(text.slice(from, range.start), messageAt);
      out += text.slice(range.start, range.end);
      from = range.end;
    }
    return out + decorateProseSegment(text.slice(from), messageAt);
  }
  return decorateProseSegment(text, messageAt);
}

function mergeRanges(ranges: { start: number; end: number }[]): { start: number; end: number }[] {
  const merged: { start: number; end: number }[] = [];
  for (const range of ranges.sort((a, b) => a.start - b.start || a.end - b.end)) {
    const previous = merged.at(-1);
    if (previous && range.start <= previous.end) previous.end = Math.max(previous.end, range.end);
    else merged.push({ ...range });
  }
  return merged;
}

/// Markdown's destination syntax also carries local paths, which `textLinks` intentionally does
/// not return when their extension or timestamp looks unlike a bare path. Preserve all balanced
/// destinations before inserting the parser's private time markers.
function markdownDestinations(text: string): { start: number; end: number }[] {
  const ranges: { start: number; end: number }[] = [];
  for (let marker = text.indexOf("]("); marker >= 0; marker = text.indexOf("](", marker + 2)) {
    const open = text.lastIndexOf("[", marker);
    if (open < 0 || text.slice(open + 1, marker).includes("]")) continue;
    let depth = 0;
    for (let at = marker + 2; at < text.length; at++) {
      const char = text[at];
      if (char === "(") depth++;
      else if (char === ")") {
        if (depth === 0) {
          ranges.push({ start: marker + 2, end: at });
          break;
        }
        depth--;
      }
    }
  }
  return ranges;
}

function decorateProseSegment(text: string, messageAt?: number): string {
  let out = "";
  let from = 0;
  const flush = (to: number) => {
    out += decorateSingles(text.slice(from, to), messageAt);
  };
  for (const list of clockLists(text)) {
    const encoded = list.plain
      ? text.slice(list.start, list.end)
      : encodeMatch(text.slice(list.start, list.end), messageAt);
    if (encoded === undefined) continue;
    flush(list.start);
    out += encoded;
    from = list.end;
  }
  flush(text.length);
  return out;
}

function decorateSingles(text: string, messageAt?: number): string {
  DETECT.lastIndex = 0;
  let out = "";
  let from = 0;
  for (const match of text.matchAll(DETECT)) {
    const source = match[0]!;
    if (BARE_CLOCK.test(source) && looksLikeNotAClock(text, match.index!, match.index! + source.length)) continue;
    const resolved = resolveTimestamp(source, messageAt);
    if (resolved === undefined) continue;
    out += text.slice(from, match.index) + encodeToken({ source, at: resolved, messageAt });
    from = match.index! + source.length;
  }
  return from ? out + text.slice(from) : text;
}

/** Whether the words around a bare "12:30" make it a score, ratio, line:col, duration or verse. */
function looksLikeNotAClock(text: string, start: number, end: number): boolean {
  const before = text.slice(Math.max(0, start - 32), start);
  const after = text.slice(end, end + 32);
  return (
    NOT_CLOCK_BEFORE.test(before) ||
    VERSE_BOOK.test(before) ||
    NOT_CLOCK_AFTER.test(after) ||
    UNKNOWN_ZONE_AFTER.test(after)
  );
}

function encodeMatch(source: string, messageAt?: number): string | undefined {
  const times = [...source.matchAll(CLOCK_TIMES)];
  if (!Number.isFinite(messageAt)) return undefined;
  // Walk back from the last time: it is the one nearest the message, and each earlier one is
  // the latest at or before the time that follows it.
  const resolved: number[] = [];
  let reference = messageAt!;
  for (let index = times.length - 1; index >= 0; index--) {
    const clock = parseClock(times[index]![0]);
    reference = index === times.length - 1 ? nearestClock(clock, 0, reference) : latestClock(clock, reference);
    resolved[index] = reference;
  }
  let out = "";
  let from = 0;
  times.forEach((time, index) => {
    const start = time.index!;
    // The last time keeps the zone it shares with the rest ("01:28 UTC").
    const end = index === times.length - 1 ? source.length : start + time[0].length;
    out +=
      source.slice(from, start) + encodeToken({ source: source.slice(start, end), at: resolved[index]!, messageAt });
    from = end;
  });
  return out;
}

/** Resolve one supported timestamp to epoch milliseconds. A time with no date is the occurrence
 *  nearest `messageAt`, within 12 hours either way: "08:36Z" written at 08:21Z is that day's,
 *  "23:50Z" written at 00:10Z the day before, "00:05Z" written at 23:55Z the day after. A date
 *  with no year is in the year nearest `messageAt`. An hour written with no leading zero, AM/PM
 *  or zone ("at 3:22") is whichever half of the day is nearer. */
export function resolveTimestamp(source: string, messageAt?: number): number | undefined {
  if (ISO.test(source)) {
    const parsed = Date.parse(source);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  const dated = source.match(DATED);
  const time = parseTimeOfDay(dated ? dated.groups!.time! : source);
  if (!time) return undefined;
  if (dated) return resolveDated(dated.groups!, time, messageAt);
  if (!Number.isFinite(messageAt)) return undefined;
  const reference = messageAt!;
  const nearest = nearestClock(time.clock, time.zone, reference);
  if (!time.eitherHalf) return nearest;
  const later = nearestClock({ ...time.clock, hour: time.clock.hour + 12 }, time.zone, reference);
  const distance = Math.abs(later - reference) - Math.abs(nearest - reference);
  return distance < 0 || (distance === 0 && later < nearest) ? later : nearest;
}

type Clock = { hour: number; minute: number; second: number; ms?: number };
/** The person's own zone (the page's), or a fixed offset east of UTC in minutes (UTC is 0). */
type Zone = "local" | number;
type TimeOfDay = { clock: Clock; zone: Zone; eitherHalf: boolean };

function parseTimeOfDay(text: string): TimeOfDay | undefined {
  const match = text.match(TIME_OF_DAY);
  if (!match) return undefined;
  const { hour, minute, second, fraction, half, onlyHour, onlyHalf, zone } = match.groups!;
  const meridiem = half ?? onlyHalf;
  let h = Number(hour ?? onlyHour);
  if (meridiem) {
    if (h < 1 || h > 12) return undefined;
    h = (h % 12) + (meridiem.toLowerCase() === "p" ? 12 : 0);
  } else if (h > 23) return undefined;
  const parsedZone = parseZone(zone);
  if (parsedZone === undefined) return undefined;
  const clock = {
    hour: h,
    minute: Number(minute ?? 0),
    second: Number(second ?? 0),
    ms: fraction ? Math.round(Number(fraction) * 1000) : 0,
  };
  if (clock.minute > 59 || clock.second > 59) return undefined;
  const eitherHalf = !meridiem && parsedZone === "local" && hour !== undefined && hour.length === 1 && h >= 1;
  return { clock, zone: parsedZone, eitherHalf };
}

function parseZone(zone: string | undefined): Zone | undefined {
  const text = zone?.trim();
  if (!text) return "local";
  if (text === "Z" || text === "UTC" || text === "GMT") return 0;
  const offset = text.match(/^(?:UTC|GMT)?([+-])(\d{1,2})(?::?(\d{2}))?$/);
  if (!offset) return undefined;
  const minutes = Number(offset[2]) * 60 + Number(offset[3] ?? 0);
  return offset[1] === "-" ? -minutes : minutes;
}

function resolveDated(groups: Record<string, string | undefined>, time: TimeOfDay, messageAt?: number) {
  const monthName = groups.month ?? groups.dayMonth;
  const month = monthName ? MONTHS.indexOf(monthName.slice(0, 3).toLowerCase()) : Number(groups.isoMonth) - 1;
  const day = Number(groups.isoDay ?? groups.monthDay ?? groups.day);
  const year = groups.isoYear ?? groups.monthYear ?? groups.dayYear;
  const clock = time.clock;
  if (year) return atDate(Number(year), month, day, clock, time.zone);
  // No year: the one nearest the message ("Jan 2" written in November is next year's).
  if (!Number.isFinite(messageAt)) return undefined;
  const own = new Date(messageAt!).getFullYear();
  let best: number | undefined;
  for (const candidate of [own - 1, own, own + 1]) {
    const at = atDate(candidate, month, day, clock, time.zone);
    if (at !== undefined && (best === undefined || Math.abs(at - messageAt!) < Math.abs(best - messageAt!))) best = at;
  }
  return best;
}

/** `clock` on the calendar date `year`-`month`-`day` in `zone`; undefined for a date that does not exist. */
function atDate(year: number, month: number, day: number, clock: Clock, zone: Zone): number | undefined {
  if (month < 0 || month > 11) return undefined;
  if (zone === "local") {
    const at = new Date(year, month, day, clock.hour, clock.minute, clock.second, clock.ms ?? 0);
    return at.getMonth() === month && at.getDate() === day ? at.getTime() : undefined;
  }
  const at = Date.UTC(year, month, day, clock.hour, clock.minute, clock.second, clock.ms ?? 0);
  const check = new Date(at);
  return check.getUTCMonth() === month && check.getUTCDate() === day ? at - zone * 60_000 : undefined;
}

function parseClock(time: string): Clock {
  const [hour, minute, second] = time.split(":").map(Number);
  return { hour: hour!, minute: minute!, second: second ?? 0 };
}

/** `clock` on `reference`'s calendar day in `zone`, moved by `shift` days. */
function onDay(clock: Clock, zone: Zone, reference: number, shift: number): number {
  if (zone === "local") {
    const day = new Date(reference);
    return new Date(
      day.getFullYear(),
      day.getMonth(),
      day.getDate() + shift,
      clock.hour,
      clock.minute,
      clock.second,
      clock.ms ?? 0,
    ).getTime();
  }
  const day = new Date(reference + zone * 60_000);
  return (
    Date.UTC(
      day.getUTCFullYear(),
      day.getUTCMonth(),
      day.getUTCDate() + shift,
      clock.hour,
      clock.minute,
      clock.second,
      clock.ms ?? 0,
    ) -
    zone * 60_000
  );
}

/** The occurrence of `clock` nearest `reference`; exactly 12 hours either way reads as the earlier. */
function nearestClock(clock: Clock, zone: Zone, reference: number): number {
  let best = onDay(clock, zone, reference, 0);
  for (const shift of [-1, 1]) {
    const candidate = onDay(clock, zone, reference, shift);
    const distance = Math.abs(candidate - reference);
    const bestDistance = Math.abs(best - reference);
    if (distance < bestDistance || (distance === bestDistance && candidate < best)) best = candidate;
  }
  return best;
}

/** The latest UTC occurrence of `clock` at or before `reference` (an earlier time in a list). */
function latestClock(clock: Clock, reference: number): number {
  const resolved = onDay(clock, 0, reference, 0);
  return resolved > reference ? resolved - DAY_MS : resolved;
}

function encodeToken(token: TimeToken): string {
  const message = Number.isFinite(token.messageAt) ? `|${token.messageAt}` : "";
  return `${TOKEN_START}${encodeURIComponent(token.source)}|${token.at}${message}${TOKEN_END}`;
}

function decodeToken(value: string): TimeToken | undefined {
  const match = value.match(new RegExp(`^${TOKEN_START}([^|]+)\\|(-?\\d+)(?:\\|(-?\\d+))?${TOKEN_END}$`));
  if (!match) return undefined;
  try {
    const source = decodeURIComponent(match[1]!);
    const at = Number(match[2]);
    if (!Number.isFinite(at)) return undefined;
    return match[3] === undefined ? { source, at } : { source, at, messageAt: Number(match[3]) };
  } catch {
    return undefined;
  }
}

/** Split parser-created tokens from prose before link and mention processing. */
export function splitTimeTokens(text: string): Array<string | TimeToken> {
  const out: Array<string | TimeToken> = [];
  const token = new RegExp(`${TOKEN_START}[^${TOKEN_END}]+${TOKEN_END}`, "g");
  let from = 0;
  for (const match of text.matchAll(token)) {
    if (match.index! > from) out.push(text.slice(from, match.index));
    const decoded = decodeToken(match[0]!);
    if (decoded) out.push(decoded);
    else out.push(match[0]!);
    from = match.index! + match[0]!.length;
  }
  if (from < text.length) out.push(text.slice(from));
  return out.length ? out : [text];
}

/** How a hover names its date (timeHoverDate.experiment.ts). */
export type TimeHoverDate = "date" | "other-day" | "time";

function sameLocalDay(a: number, b: number): boolean {
  return new Date(a).toDateString() === new Date(b).toDateString();
}

/** "Nov 7, 3:14 PM PST" (the year only when it is not `now`'s), or "3:14 PM PST" with no date. */
function localTime(at: number, now: number, date: TimeHoverDate, locale?: string): string {
  const withDate = date === "date" || (date === "other-day" && !sameLocalDay(at, now));
  const sameYear = new Date(at).getFullYear() === new Date(now).getFullYear();
  const fields: Intl.DateTimeFormatOptions = {
    ...(withDate ? { month: "short", day: "numeric", ...(sameYear ? {} : { year: "numeric" }) } : {}),
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  };
  try {
    return new Intl.DateTimeFormat(locale, fields).format(at);
  } catch {
    return new Intl.DateTimeFormat(undefined, fields).format(at);
  }
}

/** A count in the largest short unit `ms` reaches: `-1` reads "15 min ago", `1` "in 15 min". */
function shortRelative(ms: number, sign: 1 | -1, locale?: string): string {
  const [unit, size] = SHORT_UNITS.find(([, unitSize]) => ms >= unitSize) ?? SHORT_UNITS.at(-1)!;
  const count = Math.max(1, Math.round(ms / size));
  const format = (tag?: string) =>
    new Intl.RelativeTimeFormat(tag, { numeric: "always", style: "short" })
      .format(sign * count, unit)
      .replace(/\.(?=\s|$)/g, "");
  try {
    return format(locale);
  } catch {
    return format(undefined);
  }
}

/** A length of time in the largest short unit it reaches ("15 min", "3 hr", "1 day"). */
function shortDuration(ms: number, locale?: string): string {
  const [unit, size] = SHORT_UNITS.find(([, unitSize]) => ms >= unitSize) ?? SHORT_UNITS.at(-1)!;
  const count = Math.max(1, Math.round(ms / size));
  const format = (tag?: string) =>
    new Intl.NumberFormat(tag, { style: "unit", unit, unitDisplay: "short" }).format(count);
  try {
    return format(locale);
  } catch {
    return format(undefined);
  }
}

/** How a time the message pointed ahead to reads once it has passed (timeHoverWording.experiment.ts). */
export type TimeHoverWording = "message" | "now" | "both";

/** Whether `at` is a minute or more after the message it was written in. */
function afterMessage(at: number, messageAt?: number): messageAt is number {
  return messageAt !== undefined && Number.isFinite(messageAt) && at - messageAt >= 60_000;
}

/** The compact local time and age shown by a timestamp's hover tooltip: "12:36 AM PST, in 15 min"
 *  while it is ahead; once it has passed, "15 min after this message" for a time the message
 *  pointed ahead to, and "15 min ago" for one before it. */
export function timestampHoverLabel(
  at: number,
  now: number,
  locale?: string,
  messageAt?: number,
  wording: TimeHoverWording = "message",
  date: TimeHoverDate = "date",
): string {
  const local = localTime(at, now, date, locale);
  if (at - now >= 60_000) return `${local}, ${shortRelative(at - now, 1, locale)}`;
  const age = Math.max(0, now - at);
  const ago = age < 60_000 ? relativeTime(at, now, locale) : shortRelative(age, -1, locale);
  if (wording === "now" || !afterMessage(at, messageAt)) return `${local}, ${ago}`;
  const after = translate("transcript.timeAfterMessage", { duration: shortDuration(at - messageAt, locale) }, locale);
  return wording === "both" ? `${local}, ${ago}, ${after}` : `${local}, ${after}`;
}

/** First shared minute where the tooltip or accessible age changes. Its source token is static. */
export function nextTimestampHover(
  at: number,
  now: number,
  messageAt?: number,
  wording: TimeHoverWording = "message",
  date: TimeHoverDate = "date",
): number {
  if (!Number.isFinite(at)) return Infinity;
  const age = nextAgeChange(at, now, messageAt, wording);
  if (date === "time") return age;
  // The date's year appears or drops at a new year; "other-day" also changes at local midnight.
  const year = nextReplyTime(at, now);
  if (date === "date") return Math.min(age, year);
  const midnight = new Date(now);
  return Math.min(age, year, new Date(midnight.getFullYear(), midnight.getMonth(), midnight.getDate() + 1).getTime());
}

function nextAgeChange(at: number, now: number, messageAt: number | undefined, wording: TimeHoverWording): number {
  const ahead = at - now;
  if (ahead >= 60_000) {
    // "in N unit" changes when the rounded count drops, at the switch to a smaller unit, and
    // when the time arrives (then it reads as passed).
    const index = SHORT_UNITS.findIndex(([, size]) => ahead >= size);
    const size = SHORT_UNITS[index]![1];
    const count = Math.round(ahead / size);
    const threshold = count >= 2 ? (count - 0.5) * size : size;
    // The minute clock reads `now` floored to its minute; the label changes at the first minute
    // where `at - now` falls below the threshold (one minute ahead reads as passed).
    const change = at - threshold + 1;
    return Math.max(now + 60_000, Math.ceil(change / 60_000) * 60_000);
  }
  // A passed time the message pointed ahead to reads "N after this message": it never changes.
  if (wording === "message" && afterMessage(at, messageAt)) return Infinity;
  const age = Math.max(0, now - at);
  // Below one raw minute the tooltip uses relativeTime, whose rounded seconds can already say
  // "1 minute ago". Preserve that first update, and the switch to the short unit at 60 seconds.
  if (age < 60_000) return Math.min(nextRelativeTime(at, now), Math.ceil((at + 60_000) / 60_000) * 60_000);
  const index = SHORT_UNITS.findIndex(([, size]) => age >= size);
  const size = index < 0 ? 60_000 : SHORT_UNITS[index][1];
  const nextCount = index < 0 ? 60_000 : (Math.round(age / size) + 0.5) * size;
  const nextUnit = index > 0 ? SHORT_UNITS[index - 1][1] : Infinity;
  return Math.max(now + 60_000, Math.ceil((at + Math.min(nextCount, nextUnit)) / 60_000) * 60_000);
}
