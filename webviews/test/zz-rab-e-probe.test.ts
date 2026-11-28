import { test } from "bun:test";
import { createSimulation } from "../src/agent-session/acpmux/sim/run";
import { SCENARIOS } from "../src/agent-session/acpmux/sim/scenarios";
test("probe", () => {
  const scenario = SCENARIOS["late-steer"]!();
  const sim = createSimulation(scenario);
  let rows: any[] = [];
  scenario.steps.forEach((step, index) => {
    rows = sim.advance(index) ?? rows;
    console.log(index, step.label, "|", rows.map((r: any) => `${r.kind}:${r.id}${r.text ? "(" + String(r.text).slice(0, 14) + ")" : ""}`).join("  "));
  });
});
