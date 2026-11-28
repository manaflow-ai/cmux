import { expect, test } from "bun:test";
import { EVERYWHERE } from "../src/agent-session/acpmux/sim/map";
import { runSimulation } from "../src/agent-session/acpmux/sim/run";
import { SCENARIOS } from "../src/agent-session/acpmux/sim/scenarios";
test("late-steer rows-only-append", () => {
  const each = EVERYWHERE.find((e) => e.id === "rows-only-append")!;
  expect(each.check(runSimulation(SCENARIOS["late-steer"]!()))).toEqual([]);
});
