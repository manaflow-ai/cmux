// Waiting on me: the day's agent chats as swimlanes, working and blocked on the person, from
// acpmux's `_acpmux/waiting_day` (cmux-tui/crates/acpmux/src/hub/ledger/waiting_day.rs). acpmux keeps each
// chat's status changes as they happen, in a small rolling log, so a read opens no session log.
// Everything here is pure: the reply's shape, the layout of a lane's spans as fractions of the
// shown window, and which rows a scroll position mounts.
import type { Translate } from "../i18n";

export type WaitingState = "working" | "blocked";

/** One stretch of a chat's day. Gaps between spans are idle. */
export type WaitingSpan = {
  state: WaitingState;
  start: number;
  end: number;
  /** The session log seq of the status record that began it. */
  seq: number;
  /** The turn running when it began, when acpmux knew it. */
  turnId?: string;
};

export type WaitingLane = {
  sessionId: string;
  workingMs: number;
  blockedMs: number;
  lastAt: number;
  spans: WaitingSpan[];
};

export type WaitingDay = {
  since: number;
  until: number;
  workingMs: number;
  blockedMs: number;
  /** Most blocked first, then most recent. */
  lanes: WaitingLane[];
};

export const WAITING_DAY_METHOD = "_acpmux/waiting_day";

/** The start of `now`'s day in the person's own time zone. */
export function localMidnight(now: number): number {
  const day = new Date(now);
  day.setHours(0, 0, 0, 0);
  return day.getTime();
}

const num = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined;

function parseSpan(value: unknown): WaitingSpan | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  const state = raw.state === "working" || raw.state === "blocked" ? raw.state : undefined;
  const start = num(raw.start);
  const end = num(raw.end);
  if (!state || start === undefined || end === undefined || end < start) return undefined;
  const span: WaitingSpan = { state, start, end, seq: num(raw.seq) ?? 0 };
  if (typeof raw.turnId === "string" && raw.turnId) span.turnId = raw.turnId;
  return span;
}

function parseLane(value: unknown): WaitingLane | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  if (typeof raw.sessionId !== "string" || !raw.sessionId || !Array.isArray(raw.spans)) return undefined;
  const spans = raw.spans.map(parseSpan).filter((span): span is WaitingSpan => span !== undefined);
  return {
    sessionId: raw.sessionId,
    workingMs: num(raw.workingMs) ?? 0,
    blockedMs: num(raw.blockedMs) ?? 0,
    lastAt: num(raw.lastAt) ?? 0,
    spans: spans.sort((a, b) => a.start - b.start),
  };
}

/** acpmux's reply as a day, or undefined when it is not one. A lane or span that is malformed is
 *  left out; the rest still draws. */
export function parseWaitingDay(value: unknown): WaitingDay | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  const since = num(raw.since);
  const until = num(raw.until);
  if (since === undefined || until === undefined || until < since || !Array.isArray(raw.lanes)) return undefined;
  return {
    since,
    until,
    workingMs: num(raw.workingMs) ?? 0,
    blockedMs: num(raw.blockedMs) ?? 0,
    lanes: raw.lanes.map(parseLane).filter((lane): lane is WaitingLane => lane !== undefined),
  };
}

/** A drawn stretch: spans of one state close together on screen, as one rectangle. */
export type LaidSpan = {
  state: WaitingState;
  /** Fractions of the window, 0 to 1. */
  left: number;
  width: number;
  /** The first span's start (where a jump goes) and the last one's end. */
  start: number;
  end: number;
  seq: number;
  turnId?: string;
  /** The time in this state the rectangle stands for, without the gaps it bridges. */
  ms: number;
  spans: number;
};

/** The narrowest rectangle drawn, as a fraction of the window. Spans of one state closer than
 *  this join, so a lane draws at most about 1 / MIN_WIDTH rectangles of each state. */
export const MIN_WIDTH = 0.005;

/**
 * A lane's spans inside [from, to], as rectangles. Spans of one state whose gap on screen is under
 * `minWidth` join into one; each rectangle is at least `minWidth` wide, so a one-minute wait still
 * shows. Blocked rectangles come after working ones: drawn in order, red stays on top.
 */
export function layLane(spans: readonly WaitingSpan[], from: number, to: number, minWidth = MIN_WIDTH): LaidSpan[] {
  const range = to - from;
  if (range <= 0) return [];
  const laid: Record<WaitingState, LaidSpan[]> = { working: [], blocked: [] };
  for (const span of spans) {
    const start = Math.max(span.start, from);
    const end = Math.min(span.end, to);
    if (end < start || (end === start && span.end > span.start)) continue;
    const left = (start - from) / range;
    const right = (end - from) / range;
    const list = laid[span.state];
    const last = list[list.length - 1];
    if (last && left - (last.left + last.width) < minWidth) {
      last.width = Math.max(last.width, right - last.left);
      last.end = Math.max(last.end, end);
      last.ms += end - start;
      last.spans += 1;
      continue;
    }
    const rect: LaidSpan = {
      state: span.state,
      left,
      width: right - left,
      start,
      end,
      seq: span.seq,
      ms: end - start,
      spans: 1,
    };
    if (span.turnId) rect.turnId = span.turnId;
    list.push(rect);
  }
  const widen = (rect: LaidSpan): LaidSpan => {
    if (rect.width >= minWidth) return rect;
    // Widened toward the left at the window's right edge, so it never runs past it.
    const left = Math.max(0, Math.min(rect.left, 1 - minWidth));
    return { ...rect, left, width: minWidth };
  };
  return [...laid.working.map(widen), ...laid.blocked.map(widen)];
}

/** The window a day is drawn over: from the hour its first span began (never before `since`) to
 *  `until`, so a day that started at 10:00 does not spend a third of the track on the night. */
export function dayWindow(day: Pick<WaitingDay, "since" | "until" | "lanes">): { from: number; to: number } {
  let first = day.until;
  for (const lane of day.lanes) for (const span of lane.spans) first = Math.min(first, span.start);
  const hour = new Date(Math.max(first, day.since));
  hour.setMinutes(0, 0, 0);
  const from = Math.max(day.since, hour.getTime());
  // At least an hour wide, so a day that just began still has room.
  return { from: Math.min(from, day.until - 3_600_000), to: day.until };
}

/** Whole hours inside the window, as fractions, with every `step`th labeled so at most `labels`
 *  labels show. */
export function hourTicks(from: number, to: number, labels = 6): { at: number; left: number; labeled: boolean }[] {
  const range = to - from;
  if (range <= 0) return [];
  const first = new Date(from);
  first.setMinutes(0, 0, 0);
  let at = first.getTime();
  if (at < from) at += 3_600_000;
  const hours: number[] = [];
  // Local hours: a DST change makes a step 23 or 25 hours apart only at the day's edge.
  for (; at <= to; at += 3_600_000) hours.push(at);
  const step = Math.max(1, Math.ceil(hours.length / labels));
  return hours.map((hour, index) => ({ at: hour, left: (hour - from) / range, labeled: index % step === 0 }));
}

/** The rows a scroll position mounts: the ones on screen and `overscan` more on each side. */
export function visibleRows(
  scrollTop: number,
  viewport: number,
  rowHeight: number,
  count: number,
  overscan = 1,
): { first: number; last: number } {
  if (count === 0 || rowHeight <= 0) return { first: 0, last: -1 };
  const first = Math.max(0, Math.floor(scrollTop / rowHeight) - overscan);
  const last = Math.min(count - 1, Math.ceil((scrollTop + viewport) / rowHeight) - 1 + overscan);
  return { first, last };
}

/** "1 h 42 m", "12 m", "under a minute". */
export function formatWaited(ms: number, t: Translate): string {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return t("waiting.duration.underMinute");
  if (minutes < 60) return t("waiting.duration.minutes", { minutes });
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest === 0
    ? t("waiting.duration.hours", { hours })
    : t("waiting.duration.hoursMinutes", { hours, minutes: rest });
}

/** The clock time of `at` in the person's language. */
export function clockTime(at: number, language?: string): string {
  return new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" }).format(new Date(at));
}

/** The hour of `at`, short ("9 AM", "21"). */
export function hourLabel(at: number, language?: string): string {
  return new Intl.DateTimeFormat(language, { hour: "numeric" }).format(new Date(at));
}

/** What the reply is asked again on: each listed chat's status. A chat that starts, stops or
 *  starts waiting changes it; a new message in a running chat does not. */
export function statusKey(sessions: readonly { sessionId: string; status?: string }[]): string {
  return sessions.map((session) => `${session.sessionId}:${session.status ?? ""}`).join("|");
}
