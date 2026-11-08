import { expect, test } from "bun:test";
import { translate } from "../i18n";
import {
  dayWindow,
  formatWaited,
  hourTicks,
  layLane,
  MIN_WIDTH,
  parseWaitingDay,
  statusKey,
  visibleRows,
  type WaitingSpan,
} from "./waitingModel";

const HOUR = 3_600_000;
const MINUTE = 60_000;
// Fixed fixture day: 2026-10-06, read as UTC offsets from its midnight.
const SINCE = Date.UTC(2026, 9, 6, 0, 0, 0);
const UNTIL = SINCE + 12 * HOUR;

/** A transition log as acpmux folds it: status changes into spans. */
function reply(lanes: { sessionId: string; spans: WaitingSpan[] }[]) {
  return {
    since: SINCE,
    until: UNTIL,
    workingMs: 0,
    blockedMs: lanes.reduce(
      (sum, lane) => sum + lane.spans.filter((s) => s.state === "blocked").reduce((n, s) => n + s.end - s.start, 0),
      0,
    ),
    lanes: lanes.map((lane) => ({
      ...lane,
      workingMs: 0,
      blockedMs: 0,
      lastAt: lane.spans.at(-1)?.end ?? 0,
    })),
  };
}

test("an empty day parses to no lanes", () => {
  const day = parseWaitingDay(reply([]));
  expect(day).toEqual({ since: SINCE, until: UNTIL, workingMs: 0, blockedMs: 0, lanes: [] });
});

test("a reply that is not a day is undefined, and a malformed span is left out", () => {
  expect(parseWaitingDay(undefined)).toBeUndefined();
  expect(parseWaitingDay({ since: 2, until: 1, lanes: [] })).toBeUndefined();
  const day = parseWaitingDay({
    since: SINCE,
    until: UNTIL,
    lanes: [
      {
        sessionId: "a",
        spans: [
          { state: "blocked", start: SINCE + HOUR, end: SINCE + 2 * HOUR, seq: 4, turnId: "t1" },
          { state: "sleeping", start: SINCE, end: SINCE + 1 },
          { state: "working", start: SINCE + 5, end: SINCE + 1 },
        ],
      },
      { spans: [] },
    ],
  });
  expect(day?.lanes).toHaveLength(1);
  expect(day?.lanes[0].spans).toEqual([
    { state: "blocked", start: SINCE + HOUR, end: SINCE + 2 * HOUR, seq: 4, turnId: "t1" },
  ]);
});

test("one blocked span lays out at its place in the window and keeps where it began", () => {
  const spans: WaitingSpan[] = [
    { state: "working", start: SINCE + 2 * HOUR, end: SINCE + 3 * HOUR, seq: 2 },
    { state: "blocked", start: SINCE + 3 * HOUR, end: SINCE + 6 * HOUR, seq: 3, turnId: "turn-3" },
  ];
  const laid = layLane(spans, SINCE, UNTIL);
  expect(laid.map((rect) => rect.state)).toEqual(["working", "blocked"]);
  const blocked = laid[1];
  expect(blocked.left).toBeCloseTo(0.25);
  expect(blocked.width).toBeCloseTo(0.25);
  expect(blocked.seq).toBe(3);
  expect(blocked.turnId).toBe("turn-3");
  expect(blocked.ms).toBe(3 * HOUR);
});

test("a span still open at until runs to the window's right edge", () => {
  const day = parseWaitingDay(
    reply([{ sessionId: "a", spans: [{ state: "blocked", start: UNTIL - 30 * MINUTE, end: UNTIL, seq: 9 }] }]),
  )!;
  const { from, to } = dayWindow(day);
  expect(to).toBe(UNTIL);
  const [rect] = layLane(day.lanes[0].spans, from, to);
  expect(rect.left + rect.width).toBeCloseTo(1);
});

test("spans clip to the window: a wait that began before it starts at its left edge", () => {
  const [rect] = layLane([{ state: "blocked", start: SINCE - HOUR, end: SINCE + HOUR, seq: 1 }], SINCE, UNTIL);
  expect(rect.left).toBe(0);
  expect(rect.start).toBe(SINCE);
  expect(rect.ms).toBe(HOUR);
});

test("tiny spans of one state join, and a lane draws a bounded number of rectangles", () => {
  // 2,000 one-second waits ten seconds apart, alternating with work: 4,000 status changes.
  const spans: WaitingSpan[] = [];
  for (let i = 0; i < 2000; i++) {
    const at = SINCE + i * 10_000;
    spans.push({ state: "working", start: at, end: at + 9_000, seq: 2 * i });
    spans.push({ state: "blocked", start: at + 9_000, end: at + 10_000, seq: 2 * i + 1 });
  }
  const laid = layLane(spans, SINCE, UNTIL);
  expect(laid.length).toBeLessThanOrEqual(2 * Math.ceil(1 / MIN_WIDTH));
  const blocked = laid.filter((rect) => rect.state === "blocked");
  expect(blocked.reduce((sum, rect) => sum + rect.ms, 0)).toBe(2000 * 1000);
  // A joined wait jumps to where its first part began.
  expect(blocked[0].seq).toBe(1);
  for (const rect of laid) expect(rect.width).toBeGreaterThanOrEqual(MIN_WIDTH);
});

test("a one-minute wait is drawn at the narrowest width, inside the window", () => {
  const [rect] = layLane([{ state: "blocked", start: UNTIL - MINUTE, end: UNTIL, seq: 1 }], SINCE, UNTIL);
  expect(rect.width).toBe(MIN_WIDTH);
  expect(rect.left + rect.width).toBeLessThanOrEqual(1);
});

test("50 lanes mount only the rows in the scroll window and one more each side", () => {
  const lanes = Array.from({ length: 50 }, (_, i) => ({
    sessionId: `s${i}`,
    spans: [{ state: "blocked" as const, start: SINCE + i * MINUTE, end: SINCE + (i + 5) * MINUTE, seq: i }],
  }));
  const day = parseWaitingDay(reply(lanes))!;
  expect(day.lanes).toHaveLength(50);
  expect(visibleRows(0, 6 * 24, 24, 50)).toEqual({ first: 0, last: 6 });
  expect(visibleRows(24 * 20, 6 * 24, 24, 50)).toEqual({ first: 19, last: 26 });
  expect(visibleRows(24 * 44, 6 * 24, 24, 50)).toEqual({ first: 43, last: 49 });
  expect(visibleRows(0, 0, 24, 0)).toEqual({ first: 0, last: -1 });
});

test("the window starts at the hour of the day's first span, at least an hour wide", () => {
  const day = parseWaitingDay(
    reply([
      { sessionId: "a", spans: [{ state: "working", start: SINCE + 9 * HOUR + 17 * MINUTE, end: UNTIL, seq: 1 }] },
    ]),
  )!;
  const { from } = dayWindow(day);
  expect(from).toBeLessThanOrEqual(SINCE + 9 * HOUR + 17 * MINUTE);
  expect(from).toBeGreaterThan(SINCE + 7 * HOUR);
  expect(dayWindow({ since: SINCE, until: SINCE + MINUTE, lanes: [] }).from).toBe(SINCE + MINUTE - HOUR);
});

test("hour ticks label at most six hours", () => {
  const ticks = hourTicks(SINCE, SINCE + 24 * HOUR);
  expect(ticks).toHaveLength(25);
  expect(ticks.filter((tick) => tick.labeled).length).toBeLessThanOrEqual(6);
});

test("waited time reads in hours and minutes", () => {
  expect(formatWaited(20_000, translate)).toBe("under a minute");
  expect(formatWaited(12 * MINUTE, translate)).toBe("12 m");
  expect(formatWaited(2 * HOUR, translate)).toBe("2 h");
  expect(formatWaited(HOUR + 42 * MINUTE, translate)).toBe("1 h 42 m");
});

test("the status key changes only when a status does", () => {
  const a = statusKey([{ sessionId: "a", status: "running" }]);
  expect(statusKey([{ sessionId: "a", status: "running" }])).toBe(a);
  expect(statusKey([{ sessionId: "a", status: "waiting" }])).not.toBe(a);
});
