import { expect, test } from "bun:test";
import { MAP } from "../src/agent-session/acpmux/sim/map";
import { runSimulation } from "../src/agent-session/acpmux/sim/run";
import { SCENARIOS } from "../src/agent-session/acpmux/sim/scenarios";
test("incoming-burst", () => {
  const entry = MAP.find((each) => each.id === "incoming-burst")!;
  expect(entry.check!(runSimulation(SCENARIOS[entry.scenario!]!()))).toEqual([]);
});
