// l10n-allow-file: test fixture text, not shipped UI.
// A turn the agent ran on its own after the person's turn ended (a background task's notice woke it)
// draws in that turn's tail. Its runs drew folded while any later turn ran (`liveTurn`) and unfolded,
// every group of calls on its own line, once the chat stopped, so a coordinator woken by background
// tasks every few seconds read its earlier work collapse and expand at each start and end, the rows
// under it jumping and the end's fold drawing its copies over them (cmux#45943: chat content
// "loads, unloads and blinks while the agent writes or thinks", paragraphs drawn twice over each
// other). An ended run in the tail draws the same, folded, whether a later turn runs or not.
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

/// How the ended background turn's run draws: its fold and its calls.
function drawnRun(rows: readonly AcpmuxRow[]) {
  const drawn = rows.filter((entry) => entry.id === "check");
  expect(drawn).toHaveLength(1);
  const [only] = drawn;
  return { foldRun: only!.foldRun === true, settled: only!.settled === true, calls: only!.items?.length };
}

for (const agentFamily of ["claude", "codex", undefined])
  test(`${agentFamily ?? "default"}: an ended background turn's run draws the same whether a later turn runs or not`, () => {
    const idle = drawnRun(turnView(transcript("none"), new Set(), { now: 60_000, agentFamily }));
    const running = drawnRun(turnView(transcript("running"), new Set(), { now: 90_000, agentFamily, working: true }));
    const endedAgain = drawnRun(turnView(transcript("ended"), new Set(), { now: 120_000, agentFamily }));
    // Folded into its summary line, as the running turn's shape draws it, at every step.
    expect(idle).toEqual({ foldRun: true, settled: true, calls: 3 });
    expect(running).toEqual(idle);
    expect(endedAgain).toEqual(idle);
  });

test("the latest background turn's run stays folded once it ends", () => {
  const running = turnView(transcript("running"), new Set(), { now: 90_000, agentFamily: "claude", working: true });
  const ended = turnView(transcript("ended"), new Set(), { now: 120_000, agentFamily: "claude" });
  const verify = (rows: readonly AcpmuxRow[]) => rows.find((entry) => entry.id === "verify");
  // While it runs, its call in flight is on the live line; once it ends, the run is its folded line.
  expect(verify(ended)).toMatchObject({ foldRun: true, settled: true });
  expect(verify(running)?.foldRun ?? true).toBe(true);
});
