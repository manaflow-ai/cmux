// l10n-allow-file: fixture step titles, not shipped UI.
// How a helper's transcript in the Background tasks panel groups the work between its replies
// (subagentTranscriptModel.ts `transcriptBlocks`), as Claude Code's drill-in does.
import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { SUBAGENTS } from "../subagents/subagentFold";
import { carryRange, MOUNTED, runFold, transcriptBlocks, windowRange } from "./subagentTranscriptModel";

let seq = 0;
const call = (status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: "step",
  tool: { id: `t${++seq}`, title: "step", kind: "execute", status },
});
const thought: AcpmuxActivity = { kind: "thought", text: "thinking" };
const work = (id: string, ...items: AcpmuxActivity[]): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind: "activity",
  items,
});
const reply = (id: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "assistant", text: "done" });

const shape = (rows: AcpmuxRow[], fold: number) =>
  transcriptBlocks(rows, fold).map((block) =>
    block.type === "row" ? block.row.id : `run:${block.rows.map((row) => row.id).join("+")}`,
  );

describe("transcriptBlocks", () => {
  const rows = [
    work("a", thought, call()),
    work("b", call("failed")),
    work("c", call("in_progress")),
    reply("r1"),
    work("d", call()),
    reply("r2"),
    work("e", thought),
  ];

  test("two or more calls between replies fold into one run; a lone call keeps its row", () => {
    expect(shape(rows, runFold("runs"))).toEqual(["run:a+b+c", "r1", "d", "r2", "e"]);
  });

  test("a run counts its calls, its failures and whether one still runs", () => {
    const run = transcriptBlocks(rows, 2)[0]!;
    if (run.type !== "run") throw new Error("expected a run");
    expect(run.calls).toBe(3);
    expect(run.failed).toBe(1);
    expect(run.running).toBe(true);
    expect(run.items).toHaveLength(4);
  });

  test("`every` folds a lone call too; a stretch of thoughts alone never folds", () => {
    expect(shape(rows, runFold("every"))).toEqual(["run:a+b+c", "r1", "run:d", "r2", "e"]);
  });

  test("`lines` folds nothing", () => {
    expect(shape(rows, runFold("lines"))).toEqual(["a", "b", "c", "r1", "d", "r2", "e"]);
  });

  test("a nested agent's row and the prompt end a stretch", () => {
    const nested: AcpmuxRow = { id: "n", version: 1, at: 0, kind: SUBAGENTS, subagents: [] };
    const prompt: AcpmuxRow = { id: "p", version: 1, at: 0, kind: "user", text: "go" };
    expect(shape([work("a", call()), nested, work("b", call()), work("c", call()), prompt], 2)).toEqual([
      "a",
      "n",
      "run:b+c",
      "p",
    ]);
  });

  test("a run longer than the mounted window is one block, so the window over blocks mounts it whole", () => {
    const long = Array.from({ length: 2 * MOUNTED }, (_, index) => work(`w${index}`, call()));
    const blocks = transcriptBlocks([...long, reply("r")], 2);
    expect(blocks).toHaveLength(2);
    expect(windowRange(blocks)).toEqual({ start: 0 });
  });
});

// Two work rows of one call each draw as two lines until the second's next call folds them into one
// run: the window keeps the rows it mounted (SubagentTranscript.tsx), it never jumps to the newest.
describe("carryRange", () => {
  const thoughtOnly = work("y", thought);
  const before = transcriptBlocks([reply("r0"), work("x", call()), thoughtOnly, reply("r1"), reply("r2")], 2);
  const after = transcriptBlocks(
    [reply("r0"), work("x", call()), work("y", thought, call()), reply("r1"), reply("r2")],
    2,
  );

  test("the fold is the case: the same rows draw one block fewer", () => {
    expect(before.map((block) => block.id)).toEqual(["r0", "x", "y", "r1", "r2"]);
    expect(after.map((block) => block.id)).toEqual(["r0", "x", "r1", "r2"]);
  });

  test("a window whose first block folds into the one above starts at the run", () => {
    expect(carryRange(before, after, { start: 2, end: 4 })).toEqual({ start: 1, end: 3 });
  });

  test("a window whose last block folds with the one below keeps the whole run", () => {
    expect(carryRange(before, after, { start: 0, end: 2 })).toEqual({ start: 0, end: 2 });
  });

  test("a window after the fold moves up by the block it lost", () => {
    expect(carryRange(before, after, { start: 3, end: 4 })).toEqual({ start: 2, end: 3 });
    expect(carryRange(before, after, { start: 3 })).toEqual({ start: 2 });
  });

  test("a window whose start row is gone takes the newest window", () => {
    expect(carryRange(before, transcriptBlocks([reply("n0")], 2), { start: 3, end: 4 })).toEqual({ start: 0 });
  });
});
