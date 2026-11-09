// l10n-allow-file: fixture step titles, not shipped UI.
// How a helper's transcript in the Background tasks panel groups the work between its replies
// (subagentTranscriptModel.ts `transcriptBlocks`), as Claude Code's drill-in does.
import { describe, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { SUBAGENTS } from "../subagents/subagentFold";
import { runFold, transcriptBlocks } from "./subagentTranscriptModel";

let seq = 0;
const call = (status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: "step",
  tool: { id: `t${++seq}`, title: "step", kind: "execute", status },
});
const thought: AcpmuxActivity = { kind: "thought", text: "thinking" };
const work = (id: string, ...items: AcpmuxActivity[]): AcpmuxRow => ({ id, version: 1, at: 0, kind: "activity", items });
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
});
