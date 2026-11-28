import { expect, test } from "bun:test";
import { MAP } from "../src/agent-session/acpmux/sim/map";
import { runSimulation } from "../src/agent-session/acpmux/sim/run";
import { SCENARIOS } from "../src/agent-session/acpmux/sim/scenarios";
test("parallel-commands", () => {
  const entry = MAP.find((each) => each.id === "parallel-commands")!;
  expect(entry.check!(runSimulation(SCENARIOS[entry.scenario!]!()))).toEqual([]);
});
