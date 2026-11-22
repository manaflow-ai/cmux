// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// A finished turn the agent ran on its own (a background task's end woke it) folds as a prompt's turn
// does: its calls under a closed "Worked for", its reply beside it (Lawrence, 2026-11-19: "in
// collapsed, literally everything but final assistant message should be collapsed"). Lucas's chat,
// 2026-11-21: under a closed "Worked for 1m 52s", each wake drew "Read bfszn29j4.output" or "Ran 3
// commands and used 3 tools" between the replies: "it just looks very broken".
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { backgroundWorkedId, hiddenRowFolds, toggleTurnFold, turnView, WORKED } from "./turns";

afterEach(() => {
  delete globalThis.cmuxExperiments;
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const line = (id: string, background: Partial<NonNullable<AcpmuxRow["background"]>> = {}) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    background: { id, trigger: "task_notification", running: false, quiet: false, hasRows: true, ...background },
  });
const call = (id: string, inBackground: string, title = "Read bfszn29j4.output") =>
  row(id, "activity", {
    inBackground,
    items: [{ kind: "tool", text: title, tool: { id, title, kind: "read", status: "completed" } }],
  });
const say = (id: string, text: string, inBackground?: string) =>
  row(id, "assistant", { text, ...(inBackground && { inBackground }) });

/// The prompt's turn, then two wakes that each ran a call and replied, then one that only ran a call.
function chat(): AcpmuxRow[] {
  at = 0;
  return [
    row("prompt", "user", { text: "Why did the rebuild exit 65?" }),
    row("ran", "activity", {
      items: [
        { kind: "tool", text: "", tool: { id: "ran", title: "tail build.log", kind: "execute", status: "completed" } },
      ],
    }),
    say("answer", "The 65 is the earlier build. A fresh rebuild runs now, and I'll report when it ends."),
    row("summary", "turnSummary", { status: "completed", durationMs: 112_000 }),
    line("bg-1"),
    call("read", "bg-1"),
    say("check", "That check shows no error in the current logs. The rebuild still runs.", "bg-1"),
    line("bg-2"),
    call("tail", "bg-2", "tail -30 reload.log"),
    call("ps", "bg-2", "ps -A"),
    say("compile", "The compile is clean, but the app is not open yet.", "bg-2"),
    line("bg-3"),
    call("pgrep", "bg-3", "pgrep -fl cleanbar"),
    row("bg-3-end", "turnSummary", { status: "completed", inBackground: "bg-3" }),
  ];
}

const drawn = (rows: AcpmuxRow[], expanded: ReadonlySet<string> = new Set()) =>
  turnView(rows, expanded, { agentFamily: "claude" }).filter((shown) => shown.kind !== "date");
const ids = (rows: AcpmuxRow[]) => rows.map((shown) => shown.id);

test("each finished wake folds its calls under a closed Worked for, its reply beside it", () => {
  const view = drawn(chat());
  expect(ids(view)).toEqual([
    "prompt",
    `${WORKED}-prompt`,
    "answer",
    "summary",
    backgroundWorkedId("bg-1"),
    "check",
    "backgroundEnd-bg-1",
    backgroundWorkedId("bg-2"),
    "compile",
    "backgroundEnd-bg-2",
    // A wake that said nothing folds to its closed line alone.
    backgroundWorkedId("bg-3"),
    "bg-3-end",
  ]);
  expect(view.filter((shown) => shown.kind === "activity")).toEqual([]);
  const second = view.find((shown) => shown.id === backgroundWorkedId("bg-2"))!;
  expect(second).toMatchObject({ kind: WORKED, foldOpen: false, status: "completed", toolCount: 2 });
  // Timed over its own rows (first call to its footer), never acpmux's longer count.
  expect(second.durationMs).toBe(2_000);
});

test("a click opens that wake's fold alone, and a second click closes it", () => {
  const rows = chat();
  const key = backgroundWorkedId("bg-2");
  const opened = toggleTurnFold(rows, new Set(), key);
  expect([...opened]).toEqual([key]);
  const view = drawn(rows, opened);
  expect(view.find((shown) => shown.id === key)?.foldOpen).toBe(true);
  // Its calls draw in their place under the open line; the other folds stay closed.
  const shownIds = ids(view);
  expect(shownIds.indexOf(key)).toBeLessThan(shownIds.indexOf("tail"));
  expect(shownIds.indexOf("tail")).toBeLessThan(shownIds.indexOf("compile"));
  expect(shownIds).not.toContain("read");
  expect(view.find((shown) => shown.id === `${WORKED}-prompt`)?.foldOpen).toBe(false);
  const closed = toggleTurnFold(rows, opened, key);
  expect(closed.has(key)).toBe(false);
  expect(drawn(rows, closed).find((shown) => shown.id === key)?.foldOpen).toBe(false);
});

test("a failed task's named line stays above its wake's closed fold", () => {
  globalThis.cmuxExperiments = { "background-turn-look": "inline" };
  const rows = chat();
  const at2 = rows.findIndex((entry) => entry.id === backgroundTurnRowId("bg-2"));
  rows[at2] = line("bg-2", {
    cause: { kind: "shell", status: "failed", weight: "failure", summary: "Background task failed" },
  });
  const shownIds = ids(drawn(rows));
  expect(shownIds.indexOf(backgroundTurnRowId("bg-2"))).toBe(shownIds.indexOf(backgroundWorkedId("bg-2")) - 1);
});

test("a wake still running draws its calls, and the finished wakes above it stay folded", () => {
  const rows = chat().slice(0, 11);
  // bg-2 runs: its line says so, and it has no footer yet.
  rows[7] = line("bg-2", { running: true, quiet: undefined });
  const view = turnView(rows, new Set(), { agentFamily: "claude", working: true });
  const shownIds = ids(view);
  expect(shownIds).toContain(backgroundWorkedId("bg-1"));
  expect(shownIds).not.toContain("read");
  expect(shownIds).not.toContain(backgroundWorkedId("bg-2"));
  // Its call is on screen under the finished wake, then the live line.
  expect(shownIds.slice(shownIds.indexOf(backgroundWorkedId("bg-1")))).toEqual([
    backgroundWorkedId("bg-1"),
    "check",
    "backgroundEnd-bg-1",
    "tail",
    "ps",
    "thinking-live",
  ]);
});

test("an earlier message of a wake folds with its calls; only its last reply stays beside the line", () => {
  at = 0;
  const rows = [
    ...chat().slice(0, 5),
    say("first", "The log shows the old module. Checking the cache next, then the rebuild's own output.", "bg-1"),
    call("read", "bg-1"),
    say("check", "That check shows no error in the current logs. The rebuild still runs.", "bg-1"),
  ];
  const shownIds = ids(drawn(rows));
  expect(shownIds.slice(shownIds.indexOf("summary") + 1)).toEqual([
    backgroundWorkedId("bg-1"),
    "check",
    "backgroundEnd-bg-1",
  ]);
});

test("a row of another turn between a wake's call and its reply stays in place, and the call still folds", () => {
  const rows = chat().slice(0, 7);
  // A subagent the prompt's turn started ends between them (no inBackground of its own).
  rows.splice(6, 0, row("done", "subagentDone", { text: "Subagent finished" }));
  const shownIds = ids(drawn(rows));
  expect(shownIds).not.toContain("read");
  expect(shownIds.indexOf(backgroundWorkedId("bg-1"))).toBeLessThan(shownIds.indexOf("done"));
  expect(shownIds.indexOf("done")).toBeLessThan(shownIds.indexOf("check"));
});

test("a wake acpmux ended with no reply and no footer folds to its closed line", () => {
  const rows = chat().slice(0, 4);
  rows.push(line("bg-9"), call("only", "bg-9", "pgrep -fl cleanbar"));
  const shownIds = ids(drawn(rows));
  expect(shownIds).toContain(backgroundWorkedId("bg-9"));
  expect(shownIds).not.toContain("only");
});

test("Find on a call a wake's closed fold hides opens that fold", () => {
  const rows = chat();
  const view = drawn(rows);
  const index = rows.findIndex((entry) => entry.id === "ps");
  expect(hiddenRowFolds(rows, view, index)).toContain(backgroundWorkedId("bg-2"));
  // Once it is open, Find needs nothing more from it.
  const opened = drawn(rows, new Set([backgroundWorkedId("bg-2")]));
  expect(hiddenRowFolds(rows, opened, index)).not.toContain(backgroundWorkedId("bg-2"));
});
