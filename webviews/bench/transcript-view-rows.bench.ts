// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// Per-event cost of the transcript's row pipeline (App.tsx turnRowsShown: turnViewFrom, then
// subagentRowsFrom) on a long chat while its last turn streams: TURNS finished turns, each with a
// thought, a read and a command, then a live turn whose reply grows by one chunk per event. Each
// event is a new rows array with only the last row new, as a snapshot is.
//   bun bench/transcript-view-rows.bench.ts [turns=500] [events=2000] [rounds=5]
// FOLDS=set (the default) passes a plain Set of open folds, which is all a base without
// conversation/viewFolds.ts has; FOLDS=normal|thinking|verbose pass viewFolds(view, ...) once, as
// App.tsx memoizes it. Prints the median over rounds of each round's p50, p95 and max per event.
/// <reference types="bun" />
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnViewFrom, type TurnView } from "../src/agent-session/acpmux/conversation/turns";
import { subagentRowsFrom, type SubagentRows } from "../src/agent-session/acpmux/subagents/subagentRows";
import { activity, assistant, summary, thought, tool, user } from "../src/gallery/fixtures/acpmux";

const TURNS = Number(process.argv[2] ?? 500);
const EVENTS = Number(process.argv[3] ?? 2000);
const ROUNDS = Number(process.argv[4] ?? 5);
const FOLDS = process.env.FOLDS ?? "set";

type Folds = Pick<ReadonlySet<string>, "has" | "size">;

async function folds(): Promise<Folds> {
  const expanded = new Set<string>();
  if (FOLDS === "set") return expanded;
  const { viewFolds } = await import("../src/agent-session/acpmux/conversation/viewFolds");
  return viewFolds(FOLDS as "normal" | "thinking" | "verbose", expanded, new Set());
}

function chatRows(): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  const at = (turn: number) => TURNS + 1 - turn;
  for (let turn = 0; turn < TURNS; turn += 1) {
    const id = `t${turn}`;
    rows.push(user(`Fix flaky test ${turn}`, at(turn), { id: `${id}-user` }));
    rows.push(
      activity(
        [
          thought(`The retry in test ${turn} races a real timer.`, { startedAt: 0, endedAt: 4_000 }),
          tool(`Read src/retry${turn}.ts`, "read", "completed", { locations: [{ path: `src/retry${turn}.ts` }] }),
          tool(`bun test retry${turn}`, "execute", "completed", { command: `bun test retry${turn}`, output: "1 pass" }),
        ],
        at(turn),
        { id: `${id}-work` },
      ),
    );
    rows.push(assistant(`Turn ${turn}: fake timers make it deterministic.`, at(turn), { id: `${id}-answer` }));
    rows.push(summary(at(turn), { id: `${id}-summary`, status: "completed", toolCount: 2, durationMs: 12_000 }));
  }
  rows.push(user("One more", 1, { id: "live-user" }));
  return rows;
}

const quantile = (sorted: readonly number[], q: number) =>
  sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
const median = (values: readonly number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;

const open = await folds();
const base = chatRows();
const rounds: { p50: number; p95: number; max: number }[] = [];
for (let round = 0; round < ROUNDS; round += 1) {
  let turns: TurnView | undefined;
  let subagents: SubagentRows | undefined;
  let rows = base;
  let reply = "";
  // The chat as first drawn, outside the timing: each event after it reshapes only what changed.
  turns = turnViewFrom(rows, open, { working: true }, turns);
  subagents = subagentRowsFrom(turns.rows, open, subagents);
  const times: number[] = [];
  for (let event = 0; event < EVENTS; event += 1) {
    reply += "word ";
    rows = [...base, assistant(reply, 0, { id: "live-answer" })];
    const start = performance.now();
    turns = turnViewFrom(rows, open, { working: true }, turns);
    subagents = subagentRowsFrom(turns.rows, open, subagents);
    times.push(performance.now() - start);
  }
  times.sort((a, b) => a - b);
  rounds.push({ p50: quantile(times, 0.5), p95: quantile(times, 0.95), max: times.at(-1)! });
}
const fmt = (ms: number) => `${(ms * 1000).toFixed(1)} µs`;
console.log(
  `FOLDS=${FOLDS} turns=${TURNS} events=${EVENTS} rounds=${ROUNDS}: p50 ${fmt(median(rounds.map((r) => r.p50)))}, ` +
    `p95 ${fmt(median(rounds.map((r) => r.p95)))}, max ${fmt(median(rounds.map((r) => r.max)))} per event`,
);
