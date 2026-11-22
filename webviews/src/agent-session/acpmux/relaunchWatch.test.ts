// The relaunch record's bookkeeping (relaunchWatch.ts), driven with frames of the test's own: a relaunch that
// redoes nothing counts all zero; a composer dip, a blank top half, a rail redraw, a row's re-render and a fold
// animation replayed on a row already read each count once, and the copy's swap to the live page alone does not.
import { expect, test } from "bun:test";
import { RelaunchRecord, type RelaunchFrame } from "./relaunchWatch";

const live = {};
const copy = {};
const railNode = {};

const frame = (at: number, over: Partial<RelaunchFrame> = {}): RelaunchFrame => ({
  at,
  composer: 80,
  rows: ["a", "b", "c"],
  topHalfRows: 2,
  scroller: true,
  rail: { node: railNode, box: "0,0,8,400" },
  layer: live,
  disconnected: [],
  ...over,
});

test("a relaunch that redoes nothing counts all zero", () => {
  const record = new RelaunchRecord(0);
  for (let at = 0; at < 200; at += 16) record.frame(frame(at));
  record.animated(50, "transitionstart", "opacity", "new-row");
  const report = record.report();
  expect(report.first_content_ms).toBe(0);
  expect(report.composer_height_changes).toBe(0);
  expect(report.chat_blank_frames).toBe(0);
  expect(report.scroll_rail_renders).toBe(0);
  expect(report.rerenders).toBe(0);
  expect(report.replayed_animations).toBe(0);
  expect(report.animations).toHaveLength(1);
});

test("nothing counts before first content", () => {
  const record = new RelaunchRecord(0);
  record.frame(frame(0, { composer: undefined, rows: [], scroller: false, rail: undefined }));
  record.mutated(["a"]);
  record.animated(5, "web-animation", "animate", "a");
  expect(record.contentShown).toBe(false);
  record.frame(frame(16));
  expect(record.report().rerenders).toBe(0);
  expect(record.report().replayed_animations).toBe(0);
});

test("each redo counts", () => {
  const record = new RelaunchRecord(0);
  record.frame(frame(0));
  record.frame(frame(16, { composer: 60 }));
  record.frame(frame(32, { composer: 80 }));
  record.frame(frame(48, { topHalfRows: 0 }));
  record.frame(frame(64, { topHalfRows: 0 }));
  record.frame(frame(80, { rail: { node: {}, box: "0,0,8,400" } }));
  record.mutated(["a", "rail", "new-row"]);
  record.animated(90, "web-animation", "animate", "rows");
  record.animated(91, "animationstart", "fold", "b");
  const report = record.report();
  expect(report.composer_height_changes).toBe(2);
  expect(report.composer_heights).toEqual([80, 60, 80]);
  expect(report.chat_blank_frames).toBe(2);
  expect(report.blank_ms).toBe(32);
  expect(report.scroll_rail_renders).toBe(2);
  expect(report.rerenders).toBe(1);
  expect(report.rerendered_rows).toEqual(["a"]);
  expect(report.replayed_animations).toBe(2);
});

test("the copy's swap to the live page draws no new rail", () => {
  const record = new RelaunchRecord(0);
  record.frame(frame(0, { layer: copy }));
  record.frame(frame(16, { layer: live, rail: { node: {}, box: "0,0,8,400" } }));
  const report = record.report();
  expect(report.copy_swaps).toBe(1);
  expect(report.scroll_rail_renders).toBe(0);
});

test("disconnected rows are listed once", () => {
  const record = new RelaunchRecord(0);
  record.frame(frame(0, { disconnected: ["Subagent disconnected: Map X"] }));
  record.frame(frame(16, { disconnected: ["Subagent disconnected: Map X"] }));
  expect(record.report().disconnected_rows).toEqual(["Subagent disconnected: Map X"]);
});
