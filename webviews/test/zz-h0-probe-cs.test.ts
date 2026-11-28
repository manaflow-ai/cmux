import { expect, test } from "bun:test";
import { runSimulation } from "../src/agent-session/acpmux/sim/run";
import { SCENARIOS } from "../src/agent-session/acpmux/sim/scenarios";
test("compact-steer narrow rule a", () => {
  const r = runSimulation(SCENARIOS["compact-steer"]!(), { width: 320 });
  expect(r.violations.filter((v: any) => v.rule.startsWith("a-") || v.rule.startsWith("b-")).map((v: any) => v.detail)).toEqual([]);
});
