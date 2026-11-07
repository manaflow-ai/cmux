import { translate } from "../i18n";
import { textLinks } from "../chips/paths";
import { nextRelativeTime, relativeTime } from "./relativeTime";

const DAY_MS = 86_400_000;
const TOKEN_START = "\uE000";
const TOKEN_END = "\uE001";
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})$/;
const CLOCK = /^(?<hour>[01]\d|2[0-3]):(?<minute>[0-5]\d)(?::(?<second>[0-5]\d))?(?<zone>Z| UTC)?$/;
const MERIDIEM = /^(?<hour>1[0-2]|0?[1-9])(?::(?<minute>[0-5]\d))?\s?(?<half>[AaPp])\.?[Mm]\.?(?<zone> UTC)?$/;
const CLOCK_TIME = "(?:[01]\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d)?";
const MERIDIEM_TIME = "(?:1[0-2]|0?[1-9])(?::[0-5]\\d)?\\s?(?:[AaPp][Mm]|[AaPp]\\.[Mm]\\.)";
// In order, each tried first at its position: an ISO timestamp; a 12-hour time ("9pm",
// "9:30 a.m.", "8:36 AM UTC"), in the person's zone unless it says UTC; a 24-hour time with Z or
// UTC; and a 24-hour time right after "at" ("at 14:30"), in the person's zone.
const DETECT = new RegExp(
  [
    "\\b\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(?::\\d{2}(?:\\.\\d+)?)?(?:Z|[+-]\\d{2}:?\\d{2})\\b",
    `(?<![\\w.:])${MERIDIEM_TIME}(?: UTC)?(?!\\w)`,
    `\\b(?<![\\d.:])${CLOCK_TIME}(?:Z| UTC)\\b`,
    `(?<=\\b[Aa]t )${CLOCK_TIME}(?![\\w:]|\\.\\d)`,
  ].join("|"),
  "g",
);
const CLOCK_TIMES = new RegExp(CLOCK_TIME, "g");
// A list or range of clock times ("23:55 and 01:28 UTC", "23:55, 00:10 and 01:28 UTC",
// "23:55–01:28 UTC") shares the zone that follows its last time. Found by a linear scan over
// the clock times, not one nested pattern, so long runs of times cannot backtrack.
const CLOCK_TOKEN = new RegExp(`(?<![\\w.:])${CLOCK_TIME}(?![\\d:])`, "g");
const CLOCK_JOIN = /^(?:\s*,\s*(?:(?:and|or)\s+)?|\s+(?:and|or|to|through|until)\s+|\s*[\u2013\u2014-]\s*)$/;
const ISO_SPAN = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?/g;
const CLOCK_ZONE = /^(?: UTC|Z)\b/;
const MAX_JOIN = 12;

/** Spans of two or more clock times joined by commas, "and", "to" or a dash, ending in a zone. */
function clockLists(text: string): Array<{ start: number; end: number }> {
  const lists: Array<{ start: number; end: number }> = [];
  let run: { start: number; end: number; count: number } | undefined;
  const close = () => {
    if (!run || run.count < 2) return;
    const zone = text.slice(run.end, run.end + 4).match(CLOCK_ZONE);
    if (zone) lists.push({ start: run.start, end: run.end + zone[0].length });
  };
  // Clock-like pieces of an ISO timestamp ("T05:21", "-07:00") are not clock times themselves.
  const iso = [...text.matchAll(ISO_SPAN)].map((m) => [m.index!, m.index! + m[0].length] as const);
  let isoAt = 0;
  for (const match of text.matchAll(CLOCK_TOKEN)) {
    const start = match.index!;
    while (isoAt < iso.length && iso[isoAt]![1] <= start) isoAt++;
    if (isoAt < iso.length && start >= iso[isoAt]![0]) {
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
    const encoded = encodeMatch(text.slice(list.start, list.end), messageAt);
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
    const resolved = resolveTimestamp(source, messageAt);
    if (resolved === undefined) continue;
    out += text.slice(from, match.index) + encodeToken({ source, at: resolved, messageAt });
    from = match.index! + source.length;
  }
  return from ? out + text.slice(from) : text;
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
    reference = index === times.length - 1 ? nearestClock(clock, "utc", reference) : latestClock(clock, reference);
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
 *  "23:50Z" written at 00:10Z the day before, "00:05Z" written at 23:55Z the day after. */
export function resolveTimestamp(source: string, messageAt?: number): number | undefined {
  if (ISO.test(source)) {
    const parsed = Date.parse(source);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  if (!Number.isFinite(messageAt)) return undefined;
  const clock = source.match(CLOCK);
  if (clock) {
    const { hour, minute, second, zone } = clock.groups!;
    const time = { hour: Number(hour), minute: Number(minute), second: Number(second ?? 0) };
    return nearestClock(time, zone ? "utc" : "local", messageAt!);
  }
  const meridiem = source.match(MERIDIEM);
  if (!meridiem) return undefined;
  const { hour, minute, half, zone } = meridiem.groups!;
  const time = {
    hour: (Number(hour) % 12) + (half!.toLowerCase() === "p" ? 12 : 0),
    minute: Number(minute ?? 0),
    second: 0,
  };
  return nearestClock(time, zone ? "utc" : "local", messageAt!);
}

type Clock = { hour: number; minute: number; second: number };
/** UTC, or the person's own zone (the page's). */
type Zone = "utc" | "local";

function parseClock(time: string): Clock {
  const [hour, minute, second] = time.split(":").map(Number);
  return { hour: hour!, minute: minute!, second: second ?? 0 };
}

/** `clock` on `reference`'s calendar day in `zone`, moved by `shift` days. */
function onDay(clock: Clock, zone: Zone, reference: number, shift: number): number {
  const day = new Date(reference);
  return zone === "utc"
    ? Date.UTC(
        day.getUTCFullYear(),
        day.getUTCMonth(),
        day.getUTCDate() + shift,
        clock.hour,
        clock.minute,
        clock.second,
      )
    : new Date(
        day.getFullYear(),
        day.getMonth(),
        day.getDate() + shift,
        clock.hour,
        clock.minute,
        clock.second,
      ).getTime();
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
  const resolved = onDay(clock, "utc", reference, 0);
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

function localTime(at: number, locale?: string): string {
  try {
    return new Intl.DateTimeFormat(locale, {
      hour: "numeric",
      minute: "2-digit",
      timeZoneName: "short",
    }).format(at);
  } catch {
    return new Intl.DateTimeFormat(undefined, {
      hour: "numeric",
      minute: "2-digit",
      timeZoneName: "short",
    }).format(at);
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
): string {
  const local = localTime(at, locale);
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
): number {
  if (!Number.isFinite(at)) return Infinity;
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
