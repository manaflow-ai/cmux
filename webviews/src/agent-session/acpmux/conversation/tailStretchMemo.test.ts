// l10n-allow-file: test fixture text, not shipped UI.
// Each ended turn in a turn's tail (one the agent ran on its own, up to its summary) keeps its shape
// while its rows and the folds it reads stay the same (turns.ts `foldTailTurnOnce`): a record coming
// into the latest one no longer shapes every ended one before it again (renderer main thread,
// 2026-11-28). What it draws must be what a whole shape draws, record by record, following the
// latest row or scrolled up with folds held open.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { turnView, turnViewFrom, withoutStretchMemo, type TurnView } from "./turns";
import { withHeldFolds } from "./turnEndHold";
import type { Folds } from "./viewFolds";

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
const notice = (id: string, seq: number, running: boolean, quiet = false) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    seq,
    background: { id, trigger: "task_notification", running, quiet, hasRows: true },
  });

type Step = { rows: AcpmuxRow[]; working: boolean; open: string[] };

/// The person's turn, ended, then background turns the agent ran on its own, streamed record by
/// record: each one's notice, its calls (updated in place as they finish), its reply and summary. A
/// late update lands in an ended one, and a fold opens and closes on the way.
function stream(turns: number): Step[] {
  at = 0;
  const rows: AcpmuxRow[] = [
    row("prompt", "user", { text: "Watch the nightly and fix it if it breaks" }),
    row("look", "activity", { items: [call("c0", "gh run view 1")], toolCount: 1 }),
    row("reply", "assistant", { text: "Watching it." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 4_000, seq: 10, turnId: "t0" }),
  ];
  const steps: Step[] = [];
  const open = new Set<string>();
  const push = (working: boolean) => steps.push({ rows: [...rows], working, open: [...open] });
  const bump = (id: string, change: Partial<AcpmuxRow>) => {
    const index = rows.findIndex((each) => each.id === id);
    rows[index] = { ...rows[index]!, ...change, version: rows[index]!.version + 1 };
  };
  push(false);
  for (let turn = 1; turn <= turns; turn += 1) {
    const bg = `bg${turn}`;
    rows.push(notice(bg, turn * 10 + 1, true, turn % 4 === 0));
    push(true);
    const calls = [call(`c${turn}a`, `gh api runs ${turn}`, "in_progress")];
    rows.push(row(`run${turn}`, "activity", { items: calls, toolCount: 1, inBackground: bg }));
    push(true);
    for (let more = 0; more < 3; more += 1) {
      const items = [
        ...calls.map((each) => ({ ...each, tool: { ...each.tool, status: "completed" } })),
        call(`c${turn}-${more}`, `rg owner ${more}`, "in_progress"),
      ];
      calls.push(items.at(-1)!);
      bump(`run${turn}`, { items, toolCount: items.length });
      push(true);
    }
    rows.push(row(`said${turn}`, "assistant", { text: `Turn ${turn} checked.`, inBackground: bg }));
    push(true);
    const index = rows.findIndex((each) => each.id === backgroundTurnRowId(bg));
    rows[index] = { ...rows[index]!, version: 2, background: { ...rows[index]!.background!, running: false } };
    rows.push(
      row(`summary${turn}`, "turnSummary", {
        status: "completed",
        durationMs: 3_000,
        seq: turn * 10 + 9,
        turnId: `t${turn}`,
      }),
    );
    push(false);
    // A late update of an ended turn's call (its row's version moves), and a fold the reader opens.
    if (turn >= 3) {
      bump(`run${turn - 2}`, { toolCount: 4 });
      push(false);
    }
    if (turn === 3) open.add("worked-backgroundTurn-bg2");
    if (turn === 5) open.delete("worked-backgroundTurn-bg2");
    if (turn >= 3) push(false);
  }
  return steps;
}

const clone = <T>(value: T): T => structuredClone(value);

/// The rows a whole shape draws for `step`: fresh row objects, no view to build on, no kept stretch.
const whole = (step: Step, agentFamily: string | undefined, held: string[]) =>
  withoutStretchMemo(() =>
    turnView(clone(step.rows), withHeldFolds(new Set(step.open), new Set(held)), {
      now: 1e9,
      working: step.working,
      agentFamily,
    }),
  );

for (const agentFamily of ["claude", "codex", undefined])
  for (const scrolled of [false, true])
    test(`${agentFamily ?? "default"}${scrolled ? ", scrolled up" : ""}: kept tail stretches draw what a whole shape draws`, () => {
      const steps = stream(6);
      let previous: TurnView | undefined;
      for (const [index, step] of steps.entries()) {
        // Scrolled up, the pane holds folds open (`withHeldFolds`): a new set of folds every update.
        const held = scrolled ? ["worked-backgroundTurn-bg1", `held-${index}`] : [];
        const expanded: Folds = withHeldFolds(new Set(step.open), new Set(held));
        const view = turnViewFrom(step.rows, expanded, { now: 1e9, working: step.working, agentFamily }, previous);
        previous = view;
        expect({ index, rows: clone(view.rows) }).toEqual({ index, rows: whole(step, agentFamily, held) });
      }
    });
