// Scratch, not committed: replays a slice and prints the drawn rows at given seqs.
import { readFileSync } from "node:fs";
import { parseRecords } from "../../src/agent-session/acpmux/sim/sanitize";
import { replayScenario } from "../../src/agent-session/acpmux/sim/script";
import { createSimulation } from "../../src/agent-session/acpmux/sim/run";
const [file, ...at] = process.argv.slice(2);
const marks = new Set(at.map(Number));
const records = parseRecords(readFileSync(file!, "utf8"));
const scenario = replayScenario(file!, records);
const run = createSimulation(scenario, { rowsInTraceUpTo: 0 });
const show = (rows: readonly any[] | undefined, label: string) => {
  console.log(`---- ${label}`);
  for (const row of rows ?? []) {
    const fold = row.foldOpen !== undefined ? `fold=${row.foldOpen ? "open" : "closed"}` : row.runOpen !== undefined ? `run=${row.runOpen}` : "";
    const text = typeof row.text === "string" ? row.text.replace(/\s+/g, " ").slice(0, 60) : "";
    const extra = row.kind === "activity" ? `items=${(row.items ?? []).map((i: any) => i.tool?.title ?? i.kind).join("|").slice(0, 60)}` : "";
    console.log(`${row.kind.padEnd(16)} ${String(row.id).slice(0, 48).padEnd(48)} ${fold} bg=${row.inBackground ?? ""} ${extra} ${text}`);
  }
};
let rows: readonly any[] | undefined;
scenario.steps.forEach((step, index) => {
  rows = run.advance(index);
  run.check(index);
  if (step.type === "event" && marks.has(step.seq)) show(rows, `seq ${step.seq} ${JSON.stringify(run.state())}`);
});
show(rows, "end");
