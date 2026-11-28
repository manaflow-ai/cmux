// The chat render pipeline experiment (rule R7, cmuxterm-hq docs/design/chat-render-pipeline.md): with it
// off a row frame's style is exactly the one before the experiment; with it on, settled rows hold their
// indexed height under `content-visibility: auto` and the running turn never does.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createElement } from "react";
import type { AcpmuxRow } from "../model";
import { WORKED } from "./turns";
import { isSettledRow, rowFrameStyle, settledBefore, settledRowHeight } from "./settledRowSkip";

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, kind, ...extra }) as AcpmuxRow;
const geometry = { heightAt: (index: number) => 100 + index };

// Two ended turns, then the running one: its prompt, a running call and the streaming reply.
const rows: AcpmuxRow[] = [
  row("u1", "user"),
  row("a1", "assistant"),
  row("w1", WORKED),
  row("u2", "user"),
  row("t2", "tool", { status: "completed" }),
  row("a2", "assistant"),
  row("u3", "user"),
  row("t3", "tool", { status: "in_progress" }),
  row("a3", "assistant", { streaming: true }),
];

test("off: no row is settled and the rows are not scanned", () => {
  expect(settledBefore(rows, false)).toBe(0);
  for (const [index, each] of rows.entries()) expect(settledRowHeight(false, each, index, 6, geometry)).toBeUndefined();
});

test("off: the row frame's style is exactly top and marginTop", () => {
  expect(rowFrameStyle(40, 40.5, undefined)).toStrictEqual({ top: 40, marginTop: 0.5 });
  expect(renderToStaticMarkup(createElement("div", { style: rowFrameStyle(40, 40.5, undefined) }))).toBe(
    '<div style="top:40px;margin-top:0.5px"></div>',
  );
});

test("on: rows of ended turns hold their indexed height, the running turn's never do", () => {
  const before = settledBefore(rows, true);
  expect(before).toBe(6);
  const held = rows.map((each, index) => settledRowHeight(true, each, index, before, geometry));
  expect(held).toEqual([100, 101, 102, 103, 104, 105, undefined, undefined, undefined]);
});

test("on: the turn's end marks settle rows in the latest turn, never one that streams or runs", () => {
  expect(isSettledRow(row("s", "turnSummary"), 9, 0)).toBe(true);
  expect(isSettledRow(row("w", WORKED), 9, 0)).toBe(true);
  expect(isSettledRow(row("f", "tool", { settled: true }), 9, 0)).toBe(true);
  expect(isSettledRow(row("a", "assistant"), 9, 0)).toBe(false);
  expect(isSettledRow(row("l", "thinking", { live: true, settled: true }), 0, 5)).toBe(false);
  expect(isSettledRow(row("p", "user", { pending: true }), 0, 5)).toBe(false);
  expect(isSettledRow(row("r", "tool", { status: "running" }), 0, 5)).toBe(false);
});

test("on: a held row's style skips it off screen at its height", () => {
  expect(rowFrameStyle(40, 40, 230)).toStrictEqual({
    top: 40,
    marginTop: 0,
    contentVisibility: "auto",
    containIntrinsicBlockSize: "auto 230px",
  });
});

test("no prompt yet: nothing is settled by position", () => {
  expect(settledBefore([row("a", "assistant", { streaming: true })], true)).toBe(0);
});
