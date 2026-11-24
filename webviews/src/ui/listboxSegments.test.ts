// A self-windowed Listbox places rows by their own heights: a list of mixed-height rows (a steer
// queue row with its line and last message) gets spacers and a window that match where each row is.
import { expect, test } from "bun:test";
import { listboxOffsets, listboxSegments } from "./Listbox";

const items = Array.from({ length: 200 }, (_, index) => ({ id: `r${index}` }));
const getKey = (item: { id: string }) => item.id;

test("measured rows keep their own heights; unmeasured rows take the measured mean", () => {
  const heights = new Map([
    ["r0", 28],
    ["r1", 72],
  ]);
  const offsets = listboxOffsets(items, getKey, heights);
  expect(offsets[1]).toBe(28);
  expect(offsets[2]).toBe(100);
  expect(offsets[3]).toBe(150);
  expect(offsets[200]).toBe(100 + 198 * 50);
  expect(listboxOffsets(items, getKey, new Map())[200]).toBe(200 * 28);
});

test("variable rows: the window starts at the row under the scroll offset, with a spacer to its top", () => {
  // Every odd row is tall (72 px), every even row short (28 px): a pair is 100 px.
  const heights = new Map(items.map((item, index) => [item.id, index % 2 ? 72 : 28]));
  const offsets = listboxOffsets(items, getKey, heights);
  const [segment] = listboxSegments(offsets, 120, 5000, 200);
  // 5000 - 200 of overscan = 4800: row 96 (a pair of 100 px per two rows) starts there.
  expect(segment.start).toBe(96);
  expect(segment.before).toBe(offsets[96]);
  expect(segment.before).toBe(4800);
  // 5000 + 400 = 5400 is row 108's top; the window runs through it.
  expect(segment.end).toBe(109);
  // The rows plus the spacers fill the list's whole height.
  const rows = offsets[segment.end] - offsets[segment.start];
  expect(segment.before + rows + (offsets[200] - offsets[segment.end])).toBe(offsets[200]);
});

test("the highlighted row outside the window mounts at its own offset", () => {
  const heights = new Map(items.map((item, index) => [item.id, index % 2 ? 72 : 28]));
  const offsets = listboxOffsets(items, getKey, heights);
  const before = listboxSegments(offsets, 3, 5000, 200);
  expect(before[0]).toEqual({ start: 3, end: 4, before: offsets[3] });
  expect(before[0].before + 72 + before[1].before).toBe(offsets[before[1].start]);
  const after = listboxSegments(offsets, 190, 0, 200);
  expect(after[1].start).toBe(190);
  expect(offsets[after[0].end] + after[1].before).toBe(offsets[190]);
});
