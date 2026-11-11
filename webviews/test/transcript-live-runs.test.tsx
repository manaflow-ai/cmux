// Codex-style tool runs while a turn runs (cx-ncc.108): a running turn keeps each run's calls in
// sight, as they arrive, and nothing folds until the turn ends (cmux#38339); the ended turn folds
// each run into one summary line ("Read 2 files and ran a command") that opens to its calls. The
// call in flight leaves the run for the turn's live line, which names it and replaces itself as
// calls go by.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ToolRows } from "../src/agent-session/acpmux/conversation/TurnRows";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

// This file covers the `runs` arm of liveTurnWork.experiment.ts: a running turn keeps its finished
// runs in sight until it ends. The shipped `line` arm (one live line, as chatgpt.com draws a running
// turn) is covered by live-turn-one-line.test.ts.
const liveTurnArmsBefore = globalThis.cmuxExperiments;
beforeAll(() => {
  globalThis.cmuxExperiments = { ...liveTurnArmsBefore, "live-turn-work": "runs" };
});
afterAll(() => {
  globalThis.cmuxExperiments = liveTurnArmsBefore;
});

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

/// The text each drawn activity row shows, by row id: of the running turn, or of `shaped`.
function drawnRuns(shaped: AcpmuxRow[] = turnView(live, new Set(), { working: true })): Record<string, string> {
  return Object.fromEntries(
    shaped
      .filter((entry) => entry.kind === "activity")
      // Tags to spaces, then one space per gap: a row's verb sits in its own element (ToolVerb.tsx).
      .map((entry) => [
        entry.id,
        renderToStaticMarkup(<ToolRows row={entry} />)
          .replace(/<[^>]+>/g, " ")
          .replace(/\s+/g, " "),
      ]),
  );
}

test("a running turn's run that text followed keeps its calls in sight; ended, it reads as one summary line", () => {
  const reads = drawnRuns().reads!;
  expect(reads).not.toContain("Read 2 files and ran a command");
  expect(reads).toContain("README.md");
  expect(reads).toContain("ls src");
  const ended = [
    ...live.slice(0, 4),
    run("commands", [call("git log", "execute"), call("wc", "execute")]),
    text("done"),
    row("s", "turnSummary", { status: "completed", toolCount: 5 }),
  ];
  const folded = drawnRuns(turnView(ended, new Set(["worked-u", "worked-between"]))).reads!;
  expect(folded).toContain("Read 2 files and ran a command");
  expect(folded).not.toContain("README.md");
  expect(folded).not.toContain("ls src");
});

test("the call in flight leaves the run for the live line", () => {
  const commands = drawnRuns().commands!;
  expect(commands).toContain("git log");
  expect(commands).not.toContain("wc -l retry.py");
  const status = turnView(live, new Set(), { working: true }).find((entry) => entry.kind === "thinking");
  expect(status?.doing).toBe("wc -l retry.py");
});

test("a thought still coming leaves the latest run; earlier ones stay", () => {
  const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text });
  const rows = [
    row("u", "user"),
    run("first", [thought("Looking around"), call("README.md", "read"), call("ls src", "execute")]),
    row("next", "assistant", { text: "next ".repeat(40) }),
    run("latest", [call("git log", "execute"), thought("Now I should check")]),
  ];
  const shaped = turnView(rows, new Set(), { working: true });
  // The latest run keeps its finished step, and the thought still coming stays out of it; the live
  // line reads Thinking the moment the call completed (Leo, 2026-11-07).
  expect(shaped.find((entry) => entry.id === "latest")!.items!.map((item) => item.kind)).toEqual(["tool"]);
  expect(shaped.find((entry) => entry.kind === "thinking")!.doing).toBeUndefined();
  expect(shaped.find((entry) => entry.id === "first")!.items).toHaveLength(3);
});

test("a run whose only step is in flight draws nothing yet", () => {
  const rows = [row("u", "user"), run("only", [call("bun test", "execute", "in_progress")])];
  const shaped = turnView(rows, new Set(), { working: true });
  expect(shaped.find((entry) => entry.id === "only")).toBeUndefined();
  expect(shaped.find((entry) => entry.kind === "thinking")?.doing).toBe("bun test");
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
  const folded = turnView(ended, open).filter((entry) => entry.kind === "activity");
  expect(folded.map((entry) => entry.foldRun)).toEqual([true, true]);
});

test("a pending harness prompt keeps one thinking line in place", () => {
  const pending = row("pending", "user", {
    text: "Start this chat",
    pending: true,
    queued: "pending-prompt",
  });
  const starting = turnView([pending], new Set(), { now: pending.at });
  const startThinking = starting.filter((entry) => entry.kind === "thinking");

  // The line under a prompt held behind its agent's start is the turn's own Thinking line (one id,
  // one version), with no start status: nothing reads "Starting Claude Code… Cancel" (Leo, 2026-11-01).
  expect(starting.map((entry) => entry.kind)).toEqual(["user", "thinking"]);
  expect(startThinking).toHaveLength(1);
  expect(startThinking[0]).toMatchObject({ id: "thinking-live", version: 1, queued: "pending-prompt", untimed: true });
  expect(starting.filter((entry) => entry.status !== undefined)).toHaveLength(0);

  const ready = turnView([{ ...pending, queued: undefined }], new Set(), { now: pending.at });
  const readyThinking = ready.filter((entry) => entry.kind === "thinking");

  expect(ready).toHaveLength(2);
  expect(readyThinking).toHaveLength(1);
  expect(readyThinking[0]).toMatchObject({ id: "thinking-live", version: 1 });
  expect(readyThinking[0]?.status).toBeUndefined();
  expect(ready.filter((entry) => entry.status !== undefined)).toHaveLength(0);
});
