// A prewarmed page that takes a hidden chat gets what the chat's last page held with the adopt event
// (pageWake.ts). The host keeps its own copy of that state until a paint report of the page says
// `appliedWake`, and while it keeps it, its copy goes before the page's own answer at the page's release
// and at quit. The page's mark for that report is wakeMark.ts. These hold its rule (decision 2026-11-16):
//
//   - the mark stays until the call of a report that carried it resolved, so a report whose call
//     failed leaves it for the next report;
//   - a call that resolves late clears no mark of a newer adopt event.
//
// No test here renders the page: that the page's paint report uses the mark this way is by a read of
// App.tsx. This file imports no package.
import { expect, test } from "bun:test";
import { wakeMark } from "../src/agent-session/acpmux/wakeMark";

test("a page that took no state reports no mark", () => {
  const mark = wakeMark();
  const report = mark.report();
  expect(report.applied).toBe(false);
  report.reached();
  expect(mark.report().applied).toBe(false);
});

test("the report after an adopt event with a state carries the mark", () => {
  const mark = wakeMark();
  mark.took();
  expect(mark.report().applied).toBe(true);
});

test("a report whose call failed leaves the mark for the next report", () => {
  const mark = wakeMark();
  mark.took();
  const lost = mark.report();
  expect(lost.applied).toBe(true);
  // The call of `lost` failed: nothing calls `reached`.
  const next = mark.report();
  expect(next.applied).toBe(true);
  next.reached();
  expect(mark.report().applied).toBe(false);
});

test("a report made before an earlier report's call resolved carries the mark too", () => {
  const mark = wakeMark();
  mark.took();
  const first = mark.report();
  const second = mark.report();
  expect([first.applied, second.applied]).toEqual([true, true]);
  first.reached();
  expect(mark.report().applied).toBe(false);
  second.reached();
  expect(mark.report().applied).toBe(false);
});

test("the mark is gone when a report that carried it reached the host", () => {
  const mark = wakeMark();
  mark.took();
  mark.report().reached();
  expect(mark.report().applied).toBe(false);
});

test("an older report's call clears no mark of a newer adopt event", () => {
  const mark = wakeMark();
  mark.took();
  const older = mark.report();
  mark.took();
  older.reached();
  expect(mark.report().applied).toBe(true);
});

test("a report with no mark clears nothing when its call resolves", () => {
  const mark = wakeMark();
  const plain = mark.report();
  mark.took();
  plain.reached();
  expect(mark.report().applied).toBe(true);
});
