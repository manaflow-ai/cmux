// Temporary debug probe (wrc-transcript-b); removed before commit.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { runSimulation } from "../src/agent-session/acpmux/sim/run";
import { parseRecords } from "../src/agent-session/acpmux/sim/sanitize";
import { replayScenario } from "../src/agent-session/acpmux/sim/script";

test("probe", () => {
  const records = parseRecords(readFileSync(join(import.meta.dir, "fixtures", "chat-sim", "leo-2205-subagent-burst.ndjson"), "utf8"));
  const whole = runSimulation(replayScenario("leo-2205-subagent-burst", records), { rowsInTraceUpTo: 0 });
  console.log("WTBSIM folds " + JSON.stringify(whole.folds.filter((f) => String(f.id).includes("1032") || f.verdict === "remapped")));
  console.log("WTBSIM verdicts " + JSON.stringify(whole.folds.map((f) => f.verdict).reduce((m: Record<string, number>, v) => ((m[v] = (m[v] ?? 0) + 1), m), {})));
  const last = whole.traces.at(-1);
  console.log("WTBSIM lastRows1032 " + JSON.stringify((last?.rows ?? []).filter((r: { id?: string }) => String(r.id).includes("1032"))));
  expect("probe-output-retained").toBe("");
});
