import { useLabelClock } from "../clock";
import { usePaneLanguage } from "../i18n";
import { textLinks } from "../chips/paths";
import { Tooltip } from "../../../ui/Tooltip";
import { nextRelativeTime, relativeTime } from "./relativeTime";
import type { ReactNode } from "react";

const DAY_MS = 86_400_000;
const TOKEN_START = "\uE000";
const TOKEN_END = "\uE001";
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})$/;
const CLOCK = /^(?<hour>[01]\d|2[0-3]):(?<minute>[0-5]\d)(?::(?<second>[0-5]\d))?(?<zone>Z| UTC)$/;
const CLOCK_TIME = "(?:[01]\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d)?";
const DETECT = new RegExp(
  `\\b(?:\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(?::\\d{2}(?:\\.\\d+)?)?(?:Z|[+-]\\d{2}:?\\d{2})|(?<![\\d.:])(?:${CLOCK_TIME}Z|${CLOCK_TIME} UTC))\\b`,
  "g",
);
const CLOCK_TIMES = new RegExp(CLOCK_TIME, "g");
// A list or range of clock times ("23:55 and 01:28 UTC", "23:55, 00:10 and 01:28 UTC",
// "23:55–01:28 UTC") shares the zone that follows its last time. Found by a linear scan over
// the clock times, not one nested pattern, so long runs of times cannot backtrack.
const CLOCK_TOKEN = new RegExp(`(?<![\\d.:])${CLOCK_TIME}(?![\\d:])`, "g");
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
  for (const match of text.matchAll(CLOCK_TOKEN)) {
    const start = match.index!;
    if (iso.some(([from, to]) => start >= from && start < to)) {
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

export type TimeToken = { source: string; at: number };

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
  if (!text || (!text.includes("Z") && !text.includes("UTC") && !text.includes("T"))) return text;
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
    out += text.slice(from, match.index) + encodeToken({ source, at: resolved });
    from = match.index! + source.length;
  }
  return from ? out + text.slice(from) : text;
}

function encodeMatch(source: string, messageAt?: number): string | undefined {
  const times = [...source.matchAll(CLOCK_TIMES)];
  if (!Number.isFinite(messageAt)) return undefined;
  // Walk back from the last time: it is the latest one at or before the message, and each
  // earlier one is the latest at or before the time that follows it.
  const resolved: number[] = [];
  let reference = messageAt!;
  for (let index = times.length - 1; index >= 0; index--) {
    reference = resolveClock(times[index]![0], reference);
    resolved[index] = reference;
  }
  let out = "";
  let from = 0;
  times.forEach((time, index) => {
    const start = time.index!;
    // The last time keeps the zone it shares with the rest ("01:28 UTC").
    const end = index === times.length - 1 ? source.length : start + time[0].length;
    out += source.slice(from, start) + encodeToken({ source: source.slice(start, end), at: resolved[index]! });
    from = end;
  });
  return out;
}

/** Resolve one supported timestamp to epoch milliseconds. Bare UTC clocks use messageAt's date. */
export function resolveTimestamp(source: string, messageAt?: number): number | undefined {
  if (ISO.test(source)) {
    const parsed = Date.parse(source);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  const clock = source.match(CLOCK);
  if (!clock || !Number.isFinite(messageAt)) return undefined;
  const { hour, minute, second } = clock.groups!;
  return resolveClock(`${hour}:${minute}${second === undefined ? "" : `:${second}`}`, messageAt!);
}

/** The latest UTC occurrence of an "HH:MM[:SS]" clock time at or before `reference`. */
function resolveClock(time: string, reference: number): number {
  const [hour, minute, second] = time.split(":").map(Number);
  const day = new Date(reference);
  const resolved = Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), day.getUTCDate(), hour!, minute!, second ?? 0);
  return resolved > reference ? resolved - DAY_MS : resolved;
}

function encodeToken(token: TimeToken): string {
  return `${TOKEN_START}${encodeURIComponent(token.source)}|${token.at}${TOKEN_END}`;
}

function decodeToken(value: string): TimeToken | undefined {
  const match = value.match(new RegExp(`^${TOKEN_START}([^|]+)\\|(-?\\d+)${TOKEN_END}$`));
  if (!match) return undefined;
  try {
    const source = decodeURIComponent(match[1]!);
    const at = Number(match[2]);
    return Number.isFinite(at) ? { source, at } : undefined;
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

/** The compact local time and age shown by a timestamp's hover tooltip. */
export function timestampHoverLabel(at: number, now: number, locale?: string): string {
  const age = Math.max(0, now - at);
  if (age < 60_000) return `${localTime(at, locale)}, ${relativeTime(at, now, locale)}`;
  const [unit, size] = SHORT_UNITS.find(([, unitSize]) => age >= unitSize) ?? SHORT_UNITS.at(-1)!;
  const count = Math.max(1, Math.round(age / size));
  let relative: string;
  try {
    relative = new Intl.RelativeTimeFormat(locale, { numeric: "always", style: "short" })
      .format(-count, unit)
      .replace(/\.(?=\s|$)/g, "");
  } catch {
    relative = `${count} ${unit === "minute" ? "min" : unit === "hour" ? "hr" : "day"} ago`;
  }
  return `${localTime(at, locale)}, ${relative}`;
}

/** First shared minute where the tooltip or accessible age changes. Its source token is static. */
export function nextTimestampHover(at: number, now: number): number {
  if (!Number.isFinite(at)) return Infinity;
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

export function TimeHover({ token }: { token: TimeToken }): ReactNode {
  const now = useLabelClock(token.at, nextTimestampHover);
  const locale = usePaneLanguage();
  const label = timestampHoverLabel(token.at, now, locale);
  return (
    <Tooltip label={label} side="top">
      <time
        className="cv-time-hover"
        dateTime={new Date(token.at).toISOString()}
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- timestamp tooltips are keyboard-focusable without an action
        tabIndex={0}
        aria-label={`${token.source}, ${label}`}
      >
        {token.source}
      </time>
    </Tooltip>
  );
}
