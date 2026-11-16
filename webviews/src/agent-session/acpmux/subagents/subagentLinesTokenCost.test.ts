// l10n-allow-file: test fixture text, not shipped UI.
// A streamed token in a long chat that has a subagent group costs the rows it changed, not the
// chat (Leo, 2026-11-12: "even if a chat is long, there should be no percievable difference").
// `withSubagentLines` (runningTray.ts) made a new array of every row on each update and said nothing
// of its kept prefix, so every pass after it (turns.ts `turnViewFrom`, the layout) walked the whole
// chat again to find where it changed.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "../conversation/backgroundTurns";
import { keptPrefix, noteKeptPrefix, prefixWalks } from "../conversation/prefixFlatMap";
import { withSubagentLines, type DoneLineCache } from "./runningTray";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const agent: Subagent = {
  id: "chat/toolu_fix",
  parent: null,
  name: "general-purpose",
  task: "Fix it",
  state: "completed",
  startedAt: 2_000,
  endedAt: 5_000,
};
const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});
const report = (at: number): AcpmuxRow =>
  row(backgroundTurnRowId("report"), BACKGROUND_TURN, at, {
    background: {
      id: "report",
      trigger: "task_notification",
      running: false,
      quiet: true,
      hasRows: true,
      cause: { kind: "subagent", status: "completed", weight: "result", origin: "toolu_fix", summary: "Fixed" },
    },
  });

/// A chat of `count` rows with one subagent group near its start, ending in a streaming reply.
function chat(count: number): AcpmuxRow[] {
  const rows = [
    row("prompt", "user", 1_000, { text: "Fix it" }),
    row("group", SUBAGENTS, 1_500, { subagents: [agent] }),
  ];
  for (let index = rows.length; index < count; index += 1)
    rows.push(row(`r${index}`, "assistant", 6_000 + index, { text: `reply ${index}` }));
  return rows;
}

/// The next snapshot, as the client makes it: the last row a new object, the rest kept and said so.
function token(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const last = rows.at(-1)!;
  const next = [...rows.slice(0, -1), { ...last, version: last.version + 1, text: `${last.text} more` }];
  noteKeptPrefix(next, rows, rows.length - 1);
  return next;
}

const shape = (rows: readonly AcpmuxRow[]) => rows.map((entry) => `${entry.id}@${entry.version}`);

test("a streamed token in a 20,000-row chat with a subagent group walks fewer than 100 rows after the tray's pass", () => {
  const cache: DoneLineCache = new Map();
  const first = chat(20_000);
  const before = withSubagentLines(first, cache);
  const next = token(first);
  const walked = prefixWalks.rows;
  const after = withSubagentLines(next, cache);
  // The next pass (turns.ts `turnViewFrom`) asks where the rows changed.
  const kept = keptPrefix(before, after);
  expect(prefixWalks.rows - walked).toBeLessThan(100);
  // Every row but the streaming one is kept (the started and done lines add one each).
  expect(kept).toBe(after.length - 1);
  expect(shape(after)).toEqual(shape(withSubagentLines(next)));
});

test("rows kept across updates draw what a fresh pass draws, as a report moves its done line", () => {
  const cache: DoneLineCache = new Map();
  let rows = chat(40);
  let out = withSubagentLines(rows, cache);
  expect(shape(out)).toEqual(shape(withSubagentLines(rows)));
  rows = token(rows);
  out = withSubagentLines(rows, cache);
  expect(shape(out)).toEqual(shape(withSubagentLines(rows)));
  // The subagent's report arrives at the tail: its done line moves from after the group to above it.
  const withReport = [...rows, report(90_000)];
  noteKeptPrefix(withReport, rows, rows.length);
  const moved = withSubagentLines(withReport, cache);
  expect(shape(moved)).toEqual(shape(withSubagentLines(withReport)));
  expect(keptPrefix(out, moved)).toBeLessThanOrEqual(3);
  // A token after the report keeps every row but the last.
  const streamed = [...withReport, row("tail", "assistant", 91_000, { text: "ok" })];
  noteKeptPrefix(streamed, withReport, withReport.length);
  const last = withSubagentLines(streamed, cache);
  expect(shape(last)).toEqual(shape(withSubagentLines(streamed)));
  // The same rows give the same array back.
  expect(withSubagentLines(streamed, cache)).toBe(last);
});
