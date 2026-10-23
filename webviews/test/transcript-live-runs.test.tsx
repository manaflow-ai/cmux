// Codex-style tool runs while a turn runs (cx-ncc.108, the Debug toggle
// agentPane.debug.codexToolRuns, on by default): the Codex desktop app never lets a running turn's
// tool calls pile up as a list. Each run folds into one summary line ("Read 2 files, ran a command")
// that opens to its calls, the latest run too as its calls finish; the call in flight leaves the
// run for the turn's live line, which names it and replaces itself as calls go by. Off, every call
// keeps its row.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ToolRows } from "../src/agent-session/acpmux/conversation/TurnRows";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const call = (id: string, kind: string, status = "completed") => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind, status },
});
const run = (id: string, calls: AcpmuxActivity[]) => row(id, "activity", { items: calls });
const text = (id: string) => row(id, "assistant", { text: id });

// A running turn: a plan, two reads and a listing, a sentence, then two commands, the second still
// running.
const live = [
  row("u", "user"),
  text("plan"),
  run("reads", [call("README.md", "read"), call("retry.py", "read"), call("ls src", "execute")]),
  // Text long enough to stand between the runs (a short note folds into them: turns.ts mergeShortNotes).
  row("between", "assistant", { text: "between ".repeat(30) }),
  run("commands", [call("git log", "execute"), call("wc -l retry.py", "execute", "in_progress")]),
];

/// The text each drawn activity row shows, by row id.
function drawnRuns(liveRuns: boolean): Record<string, string> {
  const shaped = turnView(live, new Set(), { working: true, liveRuns });
  return Object.fromEntries(
    shaped
      .filter((entry) => entry.kind === "activity")
      .map((entry) => [entry.id, renderToStaticMarkup(<ToolRows row={entry} />).replace(/<[^>]+>/g, " ")]),
  );
}

test("with live runs on, a run that text followed reads as one summary line", () => {
  const reads = drawnRuns(true).reads!;
  expect(reads).toContain("Read 2 files, ran a command");
  expect(reads).not.toContain("README.md");
  expect(reads).not.toContain("ls src");
});

test("with live runs on, the call in flight leaves the run for the live line", () => {
  const commands = drawnRuns(true).commands!;
  expect(commands).toContain("git log");
  expect(commands).not.toContain("wc -l retry.py");
  const status = turnView(live, new Set(), { working: true, liveRuns: true }).find((entry) => entry.kind === "working");
  expect(status?.doing).toBe("wc -l retry.py");
});

test("with live runs on, a thought still coming leaves the latest run; earlier ones stay", () => {
  const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text });
  const rows = [
    row("u", "user"),
    run("first", [thought("Looking around"), call("README.md", "read"), call("ls src", "execute")]),
    row("next", "assistant", { text: "next ".repeat(40) }),
    run("latest", [call("git log", "execute"), thought("Now I should check")]),
  ];
  const shaped = turnView(rows, new Set(), { working: true, liveRuns: true });
  const latest = shaped.find((entry) => entry.id === "latest")!;
  expect(latest.items?.map((item) => item.text ?? item.tool?.id)).toEqual([""]);
  expect(latest).toMatchObject({ foldRun: true, settled: true });
  expect(shaped.find((entry) => entry.id === "first")!.items).toHaveLength(3);
});

test("with live runs on, a run whose only step is in flight draws nothing yet", () => {
  const rows = [row("u", "user"), run("only", [call("bun test", "execute", "in_progress")])];
  const shaped = turnView(rows, new Set(), { working: true, liveRuns: true });
  expect(shaped.find((entry) => entry.id === "only")).toBeUndefined();
  expect(shaped.find((entry) => entry.kind === "working")?.doing).toBe("bun test");
});

test("an ended turn's open Worked for folds each run into its summary line", () => {
  const ended = [
    ...live.slice(0, 4),
    run("commands", [call("git log", "execute"), call("wc", "execute")]),
    text("done"),
    row("s", "turnSummary", { status: "completed", toolCount: 5 }),
  ];
  // The long text between the runs is a takeaway, so each run folds under its own line.
  const open = new Set(["worked-u", "worked-between"]);
  const folded = turnView(ended, open, { liveRuns: true }).filter((entry) => entry.kind === "activity");
  expect(folded.map((entry) => entry.foldRun)).toEqual([true, true]);
  const listed = turnView(ended, open, { liveRuns: false }).filter((entry) => entry.kind === "activity");
  expect(listed.map((entry) => entry.foldRun)).toEqual([undefined, undefined]);
});

test("with live runs off, a running turn lists every call", () => {
  const runs = drawnRuns(false);
  expect(runs.reads).toContain("ls src");
  expect(runs.commands).toContain("git log");
  expect(runs.commands).toContain("wc -l retry.py");
});

test("a pending harness prompt keeps one thinking line in place", () => {
  const pending = row("pending", "user", {
    text: "Start this chat",
    pending: true,
    status: "Starting Claude Code…",
    queued: "pending-prompt",
  });
  const starting = turnView([pending], new Set(), { now: pending.at });
  const startThinking = starting.filter((entry) => entry.kind === "thinking");

  expect(starting.map((entry) => entry.kind)).toEqual(["user", "thinking"]);
  expect(startThinking).toHaveLength(1);
  expect(startThinking[0]).toMatchObject({
    id: "thinking-live",
    version: 0,
    status: "Starting Claude Code…",
    queued: "pending-prompt",
  });
  expect(starting.filter((entry) => entry.status !== undefined)).toHaveLength(1);

  const ready = turnView([{ ...pending, status: undefined }], new Set(), { now: pending.at });
  const readyThinking = ready.filter((entry) => entry.kind === "thinking");

  expect(ready).toHaveLength(2);
  expect(readyThinking).toHaveLength(1);
  expect(readyThinking[0]).toMatchObject({ id: "thinking-live", version: 1 });
  expect(readyThinking[0]?.status).toBeUndefined();
  expect(ready.filter((entry) => entry.status !== undefined)).toHaveLength(0);
});
