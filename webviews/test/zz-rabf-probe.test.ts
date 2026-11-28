import { test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { runSimulation } from "../src/agent-session/acpmux/sim/run";
import { parseRecords, replayScenario } from "../src/agent-session/acpmux/sim/script";
test("probe", () => {
  const FIX = join(import.meta.dir, "fixtures", "chat-sim");
  const records = parseRecords(readFileSync(join(FIX, "leo-2205-subagent-burst.ndjson"), "utf8"));
  const r = runSimulation(replayScenario("x", records), { rowsInTraceUpTo: 0 });
  const verdicts: Record<string, number> = {};
  for (const f of r.folds) verdicts[f.verdict] = (verdicts[f.verdict] ?? 0) + 1;
  console.log("VERDICTS", JSON.stringify(verdicts));
  console.log("1032", JSON.stringify(r.folds.filter((f) => f.id.includes("1032")).slice(0, 10)));
});
