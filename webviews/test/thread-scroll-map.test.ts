// The full-height thread minimap's model (threadMinimap/mapGeometry.ts): the rail maps the whole
// scroll height, so every prompt and reply draws at its place, the bar is the view, and a point on
// the rail scrolls the view there.
import { expect, test } from "bun:test";
import type { AcpmuxRow, ConversationLayout } from "../src/agent-session/acpmux/model";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";
import {
  MAP_HIT,
  MAP_MIN_THUMB,
  mapMarks,
  mapProgress,
  mapThumb,
  mapY,
  marksIn,
  markAt,
  scrollTopAt,
} from "../src/agent-session/acpmux/threadMinimap/mapGeometry";

const row = (id: string, kind: string, text = id): AcpmuxRow => ({ id, kind, version: 1, at: 0, text });
/// `count` turns, each a prompt 100 px tall and a reply 300 px tall.
function chat(count: number): { rows: AcpmuxRow[]; layout: ConversationLayout } {
  const rows = Array.from({ length: count }, (_, index) => [
    row(`user-${index}`, "user"),
    row(`reply-${index}`, "assistant"),
  ]).flat();
  const heights = Float64Array.from(rows, (entry) => (entry.kind === "user" ? 100 : 300));
  const tops = new Float64Array(rows.length);
  for (let index = 1; index < rows.length; index += 1) tops[index] = tops[index - 1]! + heights[index - 1]!;
  return { rows, layout: { tops, heights, totalHeight: tops.at(-1)! + heights.at(-1)! } };
}

test("every prompt and reply draws at its place, top to bottom, within the rail", () => {
  const { rows, layout } = chat(10);
  const turns = minimapTurns(rows).turns;
  const marks = mapMarks(rows, turns, layout, 400);
  expect(marks.map((mark) => mark.kind)).toEqual(Array.from({ length: 10 }, () => ["user", "agent"] as const).flat());
  expect(marks.filter((mark) => mark.kind === "user").map((mark) => mark.turn)).toEqual([...Array(10).keys()]);
  for (let index = 1; index < marks.length; index += 1) expect(marks[index]!.y).toBeGreaterThan(marks[index - 1]!.y);
  expect(marks[0]!.y).toBeGreaterThanOrEqual(0);
  expect(marks.at(-1)!.y).toBeLessThanOrEqual(400);
  // The last prompt sits about nine tenths of the way down, as it does in the chat.
  expect(marks.at(-2)!.y / 400).toBeCloseTo(3600 / 4000, 1);
});

test("replies a few px apart on a long chat draw as one mark; prompts never merge", () => {
  const { rows, layout } = chat(2000);
  const turns = minimapTurns(rows).turns;
  const marks = mapMarks(rows, turns, layout, 500);
  expect(marks.filter((mark) => mark.kind === "user")).toHaveLength(2000);
  expect(marks.filter((mark) => mark.kind === "agent").length).toBeLessThan(400);
});

test("the bar is the view: its share of the rail and its place", () => {
  const total = 4000;
  const start = mapThumb(0, 800, total, 400);
  expect(start.top).toBe(0);
  expect(start.height).toBeCloseTo((800 / 4016) * 400, 3);
  const end = mapThumb(total - 800, 800, total, 400);
  expect(end.top + end.height).toBeCloseTo(400 * ((total - 800 + 800) / 4016), 0);
  // A very long chat's bar keeps a size to grab.
  expect(mapThumb(0, 800, 400_000, 400).height).toBe(MAP_MIN_THUMB);
});

test("a point on the rail centers the view there, clamped to the chat", () => {
  expect(scrollTopAt(0, 400, 4000, 800)).toBe(0);
  expect(scrollTopAt(400, 400, 4000, 800)).toBe(3200);
  expect(scrollTopAt(200, 400, 4000, 800)).toBeCloseTo(2008 - 400, 0);
  // A mark's place and the scroll its point asks for agree.
  // (A row draws THREAD_PADDING_TOP, 16 px, below its layout top.)
  expect(scrollTopAt(mapY(2000, 4000, 400), 400, 4000, 800)).toBeCloseTo(2016 - 400, 0);
});

test("the nearest mark within reach is under the pointer; a prompt wins a tie", () => {
  const marks = [
    { kind: "agent" as const, row: 1, turn: 0, y: 50 },
    { kind: "user" as const, row: 2, turn: 1, y: 50 },
    { kind: "agent" as const, row: 3, turn: 1, y: 120 },
  ];
  expect(markAt(marks, 51)).toBe(1);
  expect(markAt(marks, 118)).toBe(2);
  expect(markAt(marks, 50 + MAP_HIT + 5)).toBeUndefined();
});

test("marks grow by their distance from the pointer", () => {
  expect(mapProgress(undefined)).toBe(0);
  expect(mapProgress(0)).toBe(1);
  expect(mapProgress(-10)).toBeGreaterThan(mapProgress(20));
  expect(mapProgress(80)).toBe(0);
});

test("finds the marks under the view without scanning the full map", () => {
  const marks = [
    { kind: "user" as const, row: 0, turn: 0, y: 10 },
    { kind: "agent" as const, row: 1, turn: 0, y: 20 },
    { kind: "user" as const, row: 2, turn: 1, y: 20 },
    { kind: "agent" as const, row: 3, turn: 1, y: 40 },
    { kind: "user" as const, row: 4, turn: 2, y: 60 },
  ];
  expect(marksIn(marks, 20, 40)).toEqual({ first: 1, last: 3 });
  expect(marksIn(marks, 21, 39)).toBeUndefined();
  expect(marksIn(marks, -10, 10)).toEqual({ first: 0, last: 0 });
  expect(marksIn(marks, 61, 80)).toBeUndefined();
});
