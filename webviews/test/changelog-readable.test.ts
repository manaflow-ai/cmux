// Leo's update to nightly 3913596493801 (2026-10-18) listed perf-split and perf-fanout commits
// under Improved, cut titles with "…", wrote "Cmux NEXT", and dumped 92 raw commit subjects with
// bead ids under All Changes. The fixture is the ten signed notes of that update's span, as
// published.
import { expect, test } from "bun:test";
import span from "../src/pages/changelog/fixtures/nightly-3913596493801-span.json";
import { mergedView } from "../src/pages/changelog/model";
import { readableChange, shortTitle } from "../src/pages/changelog/readableChange";
import type { ReleaseNotes } from "../src/pages/changelog/types";

const view = mergedView(span as ReleaseNotes[], "en");
const rows = [view.hero, ...view.groups.flatMap((g) => g.items)].filter((i) => i !== undefined);

test("work-stream commits never reach New, Improved or Fixed", () => {
  for (const row of rows) {
    expect(row.title).not.toMatch(/\bperf-|cmux next|review:/i);
    expect(row.summary).not.toMatch(/\bperf-|cmux next/i);
  }
});

test("no title is cut mid-sentence", () => {
  for (const row of rows) {
    expect(row.title.endsWith("…")).toBe(false);
    expect(row.summary.endsWith("…")).toBe(false);
  }
  const text = rows.map((r) => `${r.title} ${r.summary}`);
  expect(text.some((t) => t.includes("drops its loading spinner after 8 s"))).toBe(true);
  expect(text.some((t) => t.includes("never pinned to the traffic lights while the camera scrolls"))).toBe(true);
});

test("All Changes lists each human change once and folds internal work into a count", () => {
  expect(view.changes.length).toBeGreaterThan(0);
  expect(view.internalChanges).toBeGreaterThan(0);
  for (const change of view.changes) {
    expect(change.title).not.toMatch(/\(cx-|\bcx-\w|^(fix|feat|perf|test|docs|ci)\b.*:|perf-gate|perf-split|^Revert/i);
  }
  const prs = view.changes.flatMap((c) => (c.pr === undefined ? [] : [c.pr]));
  expect(new Set(prs).size).toBe(prs.length);
  expect(view.changes.find((c) => c.pr === 21592)?.title).toBe("Restore workspace title motion tunable");
});

test("readable change titles", () => {
  expect(readableChange("cmux NEXT perf-split: snapshot sources name a new pane's first runs (cx-8w027.14)")).toEqual({
    title: "Snapshot sources name a new pane's first runs",
    internal: true,
  });
  expect(readableChange("cmux-next strip: a moving column keeps the larger traffic-light inset until it rests")).toEqual({
    title: "A moving column keeps the larger traffic-light inset until it rests",
    internal: false,
  });
  expect(readableChange("fix(ci): pin the runner").internal).toBe(true);
  expect(readableChange("perf-gate: a switch budget of 0 sidebar row configures (cx-8w027.17)").internal).toBe(true);
  expect(readableChange("test(cmux-next): CSI 996 reports dark").internal).toBe(true);
  expect(readableChange("fix(cmux-next): restore workspace title motion tunable").title).toBe(
    "Restore workspace title motion tunable",
  );
});

test("short titles end at a clause, never inside one", () => {
  expect(shortTitle("Terminals in the keep-alive band keep drawing, so a column scrolled in is never blank")).toBe(
    "Terminals in the keep-alive band keep drawing",
  );
  expect(shortTitle("An agent page that never paints drops its loading spinner after 8 s")).toBeUndefined();
  expect(shortTitle("A tab dropped on a strip lands by the pointer")).toBe("A tab dropped on a strip lands by the pointer");
});
