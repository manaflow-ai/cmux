// What the transcript pane spends, per streamed snapshot, finding the prompts a chat can edit: the
// full read it did (editableTurns, then editableKey to compare) against the tracked read (trackEditableTurns),
// which reads only the rows after the first that changed. One iteration is one token: the last row
// is replaced by a new object, the others keep theirs (the list copy per token is not timed).
//   bun bench/edit-turns-stream.bench.ts [rounds=9] [snapshots=300]
import {
  editableKey,
  editableTurns,
  trackEditableTurns,
  type EditableTurns,
} from "../src/agent-session/acpmux/conversation/editPrompt";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const ROUNDS = Number(process.argv[2] ?? 9);
const SNAPSHOTS = Number(process.argv[3] ?? 300);
const SIZES = [1000, 5000, 20000];

const row = (fields: Record<string, unknown>) => fields as unknown as AcpmuxRow;
function chatOf(size: number): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [];
  for (let turn = 0; rows.length < size; turn += 1)
    rows.push(
      row({ kind: "user", id: `u${turn}`, text: "prompt" }),
      row({ kind: "assistant", id: `a${turn}`, text: "answer" }),
      row({ kind: "tool", id: `t${turn}` }),
      row({ kind: "turnSummary", id: `s${turn}`, seq: turn }),
    );
  return rows;
}

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;

function measure(size: number, arm: "full" | "tracked"): number {
  const samples: number[] = [];
  for (let round = 0; round < ROUNDS + 1; round += 1) {
    const base = chatOf(size).slice(0, -1);
    // Built before the clock starts: copying the list is the reducer's cost, not the read's.
    const snapshots = Array.from({ length: SNAPSHOTS }, (_, at) => [
      ...base,
      row({ kind: "assistant", id: "stream", text: `t${at}` }),
    ]);
    let tracked: EditableTurns | undefined;
    let sink = 0;
    const started = performance.now();
    for (const rows of snapshots) {
      if (arm === "full") sink += editableKey(editableTurns(rows, "claude")).length;
      else sink += (tracked = trackEditableTurns(rows, "claude", tracked)).seqs.size;
    }
    const elapsed = (performance.now() - started) / SNAPSHOTS;
    if (sink < 0) throw new Error("unreachable");
    if (round > 0) samples.push(elapsed);
  }
  return median(samples);
}

console.log("rows | full read ms/snapshot | tracked read ms/snapshot | median of", ROUNDS, "rounds x", SNAPSHOTS);
for (const size of SIZES) {
  console.log(`${size} | ${measure(size, "full").toFixed(4)} | ${measure(size, "tracked").toFixed(4)}`);
}
