// scratch: sanitize a slice and print the final drawn rows of its replay.
import { readFileSync, writeFileSync } from "node:fs";
import { runSimulation } from "../../src/agent-session/acpmux/sim/run";
import { parseRecords, sanitizeRecords } from "../../src/agent-session/acpmux/sim/sanitize";
import { replayScenario } from "../../src/agent-session/acpmux/sim/script";
const [input, out, lo, hi] = process.argv.slice(2);
let records = parseRecords(readFileSync(input!, "utf8"));
if (lo) records = records.filter((r) => r.seq >= Number(lo) && r.seq <= Number(hi));
const clean = out === "-" ? records : sanitizeRecords(records);
if (out !== "-") writeFileSync(out!, clean.map((r) => JSON.stringify(r)).join("\n") + "\n");
const result = runSimulation(replayScenario("x", clean), { rowsInTraceUpTo: 5000 });
const last = result.traces.at(-1)!;
console.log(`records ${clean.length} steps ${result.steps} working ${last.working}`);
for (const row of last.rows ?? []) console.log(row.kind.padEnd(16), row.fold.padEnd(7), String(row.turn).padEnd(3), row.id.slice(0, 50));
