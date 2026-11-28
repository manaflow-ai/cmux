// l10n-allow-file: test fixture prompts and subagent names, not shipped UI.
// A subagent that failed stays in sight, never hidden in the turn's "Worked for": it waits on its
// Retry. A burst of them reads as one line, "5 subagents failed", that opens to each failed row. Leo,
// 2026-11-24: "we can initiate the Worked for with these background tasks as actual tool calls. we can
// indeed treat them as tool calls, even though they're bursted at the end/start of turns. thereby we
// can have them be folded properly too."
import { afterAll, beforeAll, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { turnView, WORKED } from "./turns";

// The default fold: a finished Claude turn folds under one "Worked for".
let experimentsBefore: PropertyDescriptor | undefined;
beforeAll(() => {
  experimentsBefore = Object.getOwnPropertyDescriptor(globalThis, "cmuxExperiments");
  delete (globalThis as { cmuxExperiments?: unknown }).cmuxExperiments;
});
afterAll(() => {
  if (experimentsBefore) Object.defineProperty(globalThis, "cmuxExperiments", experimentsBefore);
});

const START = Date.UTC(2026, 10, 24, 1, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const ended = (index: number, state: string, second = 400 + index): AcpmuxRow =>
  row(`subagentDone:a${index}`, "subagentDone", second, {
    subagents: [
      {
        id: `a${index}`,
        parent: null,
        name: `helper-${index}`,
        task: `Check lane ${index}`,
        state,
        startedAt: START,
        endedAt: START + second * 1000,
      } as never,
    ],
  });
const failed = (n: number, from = 0) => Array.from({ length: n }, (_, i) => ended(from + i, "failed"));
const work = row("t-1", "activity", 1, {
  items: [{ kind: "tool", text: "", tool: { id: "c1", title: "bun test", kind: "execute", status: "completed" } }],
});
const prompt = row("u-0", "user", 0, { text: "Land the lanes" });
const steer = row("s-1", "user", 100, { text: "Also check lane 9", steer: "landed" });
const answer = row("a-1", "assistant", 300, { text: "Checked; lane 9 is green." });
const summary = row("sum", "turnSummary", 310, { status: "completed", durationMs: 310_000, toolCount: 1 });

/// The burst at the turn's end, after its summary, as the harness bursts it.
const after = (burst: AcpmuxRow[]) => [prompt, work, steer, answer, summary, ...burst];
/// The burst inside the turn, among its work, before its summary.
const within = (burst: AcpmuxRow[]) => [
  prompt,
  work,
  steer,
  ...burst.map((r, i) => ({ ...r, at: START + 200_000 + i })),
  answer,
  summary,
];

const view = (rows: AcpmuxRow[], expanded: ReadonlySet<string> = new Set()) =>
  turnView(rows, expanded, { agentFamily: "claude", now: START + 900_000 }).filter((r) => r.kind !== "date");
const ids = (rows: AcpmuxRow[]) => rows.map((r) => r.id);
const ends = (rows: AcpmuxRow[]) => ids(rows).filter((id) => id.startsWith("subagentDone:"));
const lines = (rows: AcpmuxRow[]) => rows.filter((r) => r.backgroundRun);
const label = (line: AcpmuxRow) =>
  renderToStaticMarkup(<BackgroundTurnLine row={line} expanded={false} onToggle={() => {}} />);

test("one failed subagent draws as it came, no line over it", () => {
  for (const rows of [after(failed(1)), within(failed(1))]) {
    const shown = view(rows);
    expect(ends(shown)).toEqual(["subagentDone:a0"]);
    expect(lines(shown)).toEqual([]);
  }
});

test("five failed subagents read as one line in sight, '5 subagents failed', outside the fold", () => {
  for (const rows of [after(failed(5)), within(failed(5))]) {
    const shown = view(rows);
    expect(ends(shown)).toEqual([]);
    const [line, ...more] = lines(shown);
    expect(more).toEqual([]);
    expect(line!.backgroundRun).toMatchObject({ failed: 5, subagents: 5, subagentEnd: "failed" });
    expect(line!.foldOpen).toBe(false);
    expect(label(line!)).toContain("5 subagents failed");
    // Every "Worked for" is closed, and the line is a row of the view itself, not inside one.
    expect(shown.filter((r) => r.kind === WORKED).every((r) => !r.foldOpen)).toBe(true);
  }
});

test("opening the line shows each failed subagent's row", () => {
  for (const rows of [after(failed(5)), within(failed(5))]) {
    const line = lines(view(rows))[0]!;
    const open = view(rows, new Set([line.id]));
    expect(ends(open)).toEqual(failed(5).map((r) => r.id));
    expect(open.every((r) => r.kind !== "subagentDone" || r.subagents?.[0]?.state === "failed")).toBe(true);
  }
});

test("the person's steer between failures splits the burst and stays where it was", () => {
  const steer2 = row("s-2", "user", 450, { text: "Stop the rest", steer: "landed" });
  const shown = view([...after(failed(2)), steer2, ...failed(3, 5).map((r, i) => ({ ...r, at: START + 460_000 + i }))]);
  const [first, second, ...more] = lines(shown);
  expect(more).toEqual([]);
  expect(first!.backgroundRun).toMatchObject({ failed: 2, subagentEnd: "failed" });
  expect(second!.backgroundRun).toMatchObject({ failed: 3, subagentEnd: "failed" });
  const at = ids(shown);
  expect(at.indexOf(first!.id)).toBeLessThan(at.indexOf("s-2"));
  expect(at.indexOf("s-2")).toBeLessThan(at.indexOf(second!.id));
});

test("finished ends fold, and the failed ones among them stay one line in sight", () => {
  const burst = [
    ended(0, "completed"),
    ended(1, "failed"),
    ended(2, "completed"),
    ended(3, "failed"),
    ended(4, "failed"),
  ];
  // Inside the turn, finished ends are the turn's work, under its closed "Worked for".
  const inTurn = view(within(burst));
  expect(ends(inTurn)).toEqual([]);
  const [line, ...more] = lines(inTurn);
  expect(more).toEqual([]);
  expect(line!.backgroundRun).toMatchObject({ failed: 3, finished: 0, subagentEnd: "failed" });
  expect(line!.backgroundRun!.rows).toEqual(["subagentDone:a1", "subagentDone:a3", "subagentDone:a4"]);
  expect(label(line!)).toContain("3 subagents failed");
  const worked = inTurn.filter((r) => r.kind === WORKED);
  const opened = view(within(burst), new Set(worked.map((r) => r.id)));
  expect(ends(opened)).toEqual(expect.arrayContaining(["subagentDone:a0", "subagentDone:a2"]));
  // At the turn's end, the finished ends fold under a line of their own, the failed ones under theirs.
  const atEnd = lines(view(after(burst)));
  expect(atEnd.map((r) => r.backgroundRun)).toMatchObject([
    { finished: 2, failed: 0, subagentEnd: "finished" },
    { finished: 0, failed: 3, subagentEnd: "failed" },
  ]);
  expect(label(atEnd[0]!)).toContain("2 subagents finished");
  expect(label(atEnd[1]!)).toContain("3 subagents failed");
});
