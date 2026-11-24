// l10n-allow-file: test fixture text, not shipped UI.
// A turn the agent ran on its own after the person's turn ended (a background task's notice woke it)
// draws in that turn's tail. Its runs drew folded while any later turn ran (`liveTurn`) and unfolded,
// every group of calls on its own line, once the chat stopped, so a coordinator woken by background
// tasks every few seconds read its earlier work collapse and expand at each start and end, the rows
// under it jumping and the end's fold drawing its copies over them (cmux#45943: chat content
// "loads, unloads and blinks while the agent writes or thinks", paragraphs drawn twice over each
// other). An ended turn in the tail draws the same, its work under its closed "Worked for", whether a
// later turn runs or not (cmux#49592).
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { turnView } from "./turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const call = (id: string, title: string, status = "completed") => ({
  kind: "tool" as const,
  text: title,
  tool: { id, title, kind: "execute", status },
});
const run = (id: string, calls: ReturnType<typeof call>[], extra: Partial<AcpmuxRow> = {}) =>
  row(id, "activity", { items: calls, toolCount: calls.length, ...extra });
const notice = (id: string, seq: number, running: boolean) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    seq,
    background: { id, trigger: "task_notification", running, quiet: false, hasRows: true },
  });

/// The person's turn, a background turn that ended with its own summary, and (`next`) a second one
/// that has started: `running` while it runs a call, `ended` once it ended too.
function transcript(next: "none" | "running" | "ended"): AcpmuxRow[] {
  at = 0;
  const rows = [
    row("prompt", "user", { text: "Monitor the nightly and fix it if it breaks" }),
    run("look", [call("c1", "gh run view 1"), call("c2", "gh run view 2")]),
    row("reply", "assistant", { text: "The nightly is building; I'll watch it." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 4_000, seq: 40, turnId: "t1" }),
    notice("bg1", 41, false),
    run("check", [call("c3", "gh api runs"), call("c4", "gh api jobs"), call("c5", "rg owner")], {
      inBackground: "bg1",
    }),
    row("woken", "assistant", { text: "The run finished; checking it published.", inBackground: "bg1" }),
    row("summary-bg1", "turnSummary", { status: "completed", durationMs: 3_000, seq: 60, turnId: "t2" }),
  ];
  if (next === "none") return rows;
  rows.push(
    notice("bg2", 61, next === "running"),
    run("verify", [call("c6", "gh api steps", next === "running" ? "in_progress" : "completed")], {
      inBackground: "bg2",
    }),
  );
  if (next === "ended")
    rows.push(
      row("woken2", "assistant", { text: "It published.", inBackground: "bg2" }),
      row("summary-bg2", "turnSummary", { status: "completed", durationMs: 2_000, seq: 80, turnId: "t3" }),
    );
  return rows;
}

/// How the ended background turn draws: its one "Worked for" (closed), whether its run shows beside
/// it, and its reply (cmux#49592: every finished turn folds its work, whatever started it).
function drawnRun(rows: readonly AcpmuxRow[]) {
  const worked = rows.filter((entry) => entry.id === "worked-backgroundTurn-bg1");
  expect(worked).toHaveLength(1);
  return {
    open: worked[0]!.foldOpen === true,
    run: rows.some((entry) => entry.id === "check"),
    reply: rows.some((entry) => entry.id === "woken"),
  };
}

for (const agentFamily of ["claude", "codex", undefined])
  test(`${agentFamily ?? "default"}: an ended background turn draws the same whether a later turn runs or not`, () => {
    const idle = drawnRun(turnView(transcript("none"), new Set(), { now: 60_000, agentFamily }));
    const running = drawnRun(turnView(transcript("running"), new Set(), { now: 90_000, agentFamily, working: true }));
    const endedAgain = drawnRun(turnView(transcript("ended"), new Set(), { now: 120_000, agentFamily }));
    // Folded under its closed "Worked for", its reply in sight, at every step.
    expect(idle).toEqual({ open: false, run: false, reply: true });
    expect(running).toEqual(idle);
    expect(endedAgain).toEqual(idle);
  });

test("the latest background turn's run folds under its Worked for once it ends", () => {
  const running = turnView(transcript("running"), new Set(), { now: 90_000, agentFamily: "claude", working: true });
  const ended = turnView(transcript("ended"), new Set(), { now: 120_000, agentFamily: "claude" });
  // While it runs, its call in flight is on the live line; once it ends, its work is under one closed line.
  expect(running.some((entry) => entry.id === "worked-backgroundTurn-bg2")).toBe(false);
  expect(ended.find((entry) => entry.id === "worked-backgroundTurn-bg2")).toMatchObject({ foldOpen: false });
  expect(ended.some((entry) => entry.id === "verify")).toBe(false);
  expect(ended.some((entry) => entry.id === "woken2")).toBe(true);
});
