// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// Per-record cost of a long running turn (a coordinator steered all day: one turn that never ends,
// thousands of calls and replies, other sessions' messages into it). Each record appends a call, a
// reply or an incoming message to the running turn, as a snapshot does: a new rows array, every
// row before the new one the same object. Timed per record: the row pipeline (App.tsx
// turnRowsShown: turnViewFrom, then subagentRowsFrom) and the transcript's estimate over its rows
// (model.ts layoutConversation, given the last layout and the height cache as VirtualTranscript
// gives them), and counted: the rows the record handed the transcript as new objects (each one the
// layout places and measures again and the transcript renders again when mounted).
//   bun bench/live-turn-rows.bench.ts [records=2000] [events=300] [rounds=5]
/// <reference types="bun" />
import {
  layoutConversation,
  type AcpmuxRow,
  type ConversationLayout,
  type RowHeights,
} from "../src/agent-session/acpmux/model";
import { turnViewFrom, type TurnView } from "../src/agent-session/acpmux/conversation/turns";
import { subagentRowsFrom, type SubagentRows } from "../src/agent-session/acpmux/subagents/subagentRows";
import { activity, assistant, tool, user } from "../src/gallery/fixtures/acpmux";
import { perfRow, TARGET_MS } from "./perfRow";

const RECORDS = Number(process.argv[2] ?? 2000);
const EVENTS = Number(process.argv[3] ?? 300);
const ROUNDS = Number(process.argv[4] ?? 5);
const WIDTH = 720;

const START = 1_000_000;
/// The running turn's `index`th record after its prompt: calls, a reply after every fourth, and
/// another session's message after every tenth.
function record(index: number): AcpmuxRow {
  const at = START + index * 1_000;
  if (index % 10 === 9) {
    const text = `Lane ${index} merged, CI green on the head.`;
    return user(text, 0, {
      id: `incoming-${index}`,
      at,
      incoming: {
        kind: "message",
        message: { name: `lane-${index}`, text, raw: `lane-${index} -> coordinator: ${text}` },
      },
      // Sent into the running turn: it goes on with it (turnStart.ts `continuesTurn`).
      continues: true,
    });
  }
  if (index % 4 === 3)
    return assistant(`Lane ${index} is green; next is the review pass.`, 0, { id: `reply-${index}`, at });
  return activity(
    [tool(`gh pr checks ${index}`, "execute", "completed", { command: `gh pr checks ${index}`, output: "all green" })],
    0,
    { id: `call-${index}`, at },
  );
}

const quantile = (sorted: readonly number[], q: number) =>
  sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
const median = (values: readonly number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;

const prompt = user("Coordinate the lanes until they all land.", 0, { id: "live-user", at: START - 1_000 });
const options = { working: true, turnStartedAtMs: START - 1_000, now: START + (RECORDS + EVENTS) * 1_000 };
const rounds: { p50: number; p95: number; changed: number }[] = [];
for (let round = 0; round < ROUNDS; round += 1) {
  let rows: AcpmuxRow[] = [prompt];
  for (let index = 0; index < RECORDS; index += 1) rows.push(record(index));
  const open = new Set<string>();
  let turns: TurnView | undefined = turnViewFrom(rows, open, options);
  let subagents: SubagentRows | undefined = subagentRowsFrom(turns.rows, open);
  const known: RowHeights = new WeakMap();
  let drawn = subagents.rows;
  let layout: ConversationLayout = layoutConversation(drawn, WIDTH, new Map(), undefined, known);
  const times: number[] = [];
  const changed: number[] = [];
  for (let event = 0; event < EVENTS; event += 1) {
    rows = [...rows, record(RECORDS + event)];
    const start = performance.now();
    turns = turnViewFrom(rows, open, options, turns);
    subagents = subagentRowsFrom(turns.rows, open, subagents);
    const next = subagents.rows;
    const nextLayout = layoutConversation(next, WIDTH, new Map(), undefined, known, { rows: drawn, layout });
    times.push(performance.now() - start);
    const before = new Set(drawn);
    let fresh = 0;
    for (const row of next) if (!before.has(row)) fresh += 1;
    changed.push(fresh);
    drawn = next;
    layout = nextLayout;
  }
  times.sort((a, b) => a - b);
  rounds.push({ p50: quantile(times, 0.5), p95: quantile(times, 0.95), changed: median(changed) });
}
const fmt = (ms: number) => `${ms.toFixed(3)} ms`;
const p50 = median(rounds.map((r) => r.p50));
const p95 = median(rounds.map((r) => r.p95));
const changed = median(rounds.map((r) => r.changed));
console.log(
  `live turn of ${RECORDS} records, ${EVENTS} records appended, ${ROUNDS} rounds: p50 ${fmt(p50)}, p95 ${fmt(p95)} ` +
    `per record; ${changed} rows handed over as new objects per record (median)`,
);
perfRow({ name: `live_turn_rows.${RECORDS}.record_ms`, p50, p95, target: TARGET_MS.frameWork });
perfRow({ name: `live_turn_rows.${RECORDS}.new_rows`, p50: changed, p95: changed, unit: "rows" });
