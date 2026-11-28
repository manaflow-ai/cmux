// The chat simulator's scenario map (src/agent-session/acpmux/sim/map.ts): every way a chat's display has
// gone wrong, or plausibly can, with the behaviour expected instead, checked on the scenario that plays it.
//
// Leo, 2026-11-22: "there are probably more bullshit scenarios. we need to map them all out and note what
// expected behaviours are for all."
import { describe, expect, test } from "bun:test";
import { EVERYWHERE, MAP } from "../src/agent-session/acpmux/sim/map";
import { runSimulation, type SimResult } from "../src/agent-session/acpmux/sim/run";
import { replayScenario } from "../src/agent-session/acpmux/sim/script";
import { SCENARIOS } from "../src/agent-session/acpmux/sim/scenarios";

const runs = new Map<string, SimResult>();
const run = (name: string) => {
  if (!runs.has(name)) runs.set(name, runSimulation(SCENARIOS[name]!()));
  return runs.get(name)!;
};
const rules = (result: SimResult) =>
  result.violations
    .filter((violation) => violation.rule.startsWith("a-") || violation.rule.startsWith("b-"))
    .map((violation) => `${violation.rule} ${violation.label}: ${violation.detail}`);

/// The scenario as a pane reads a later page of it (a reconnect, a long chat opened at its end): from the
/// turn that opens nearest its middle, since pages split before a turn's opening record (direct.ts).
const fromHalfway = (name: string) => {
  const whole = SCENARIOS[name]!();
  const opens = whole.events.flatMap((event, index) =>
    event.kind === "user_message" && event.msg?.steer !== true ? [index] : [],
  );
  const middle = Math.floor(whole.events.length / 2);
  const from = opens.find((index) => index >= middle) ?? opens.at(-1) ?? 0;
  return runSimulation({
    ...replayScenario(`${name} from halfway`, whole.events.slice(from)),
    family: whole.family,
  });
};

 test("notice halfway", () => {
  const result = fromHalfway("notice-no-tool-turn");
  const each = EVERYWHERE.find((e) => e.id === "one-live-line")!;
  expect(each.check(result)).toEqual([]);
});
