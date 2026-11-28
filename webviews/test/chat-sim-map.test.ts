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

describe("chat simulator map: the map and the scenarios are one list", () => {
  test("every scenario has a map entry, and every entry's scenario exists", () => {
    const mapped = MAP.flatMap((entry) => (entry.scenario ? [entry.scenario] : []));
    expect(mapped.filter((name) => !SCENARIOS[name])).toEqual([]);
    expect(Object.keys(SCENARIOS).filter((name) => !mapped.includes(name))).toEqual([]);
  });
  test("every entry says what is expected, and is checked or says why not", () => {
    expect(new Set(MAP.map((entry) => entry.id)).size).toBe(MAP.length);
    const ids = MAP.map((entry) => entry.id);
    for (const each of EVERYWHERE) for (const id of Object.values(each.known ?? {})) expect(ids).toContain(id);
    for (const entry of MAP) {
      expect(entry.expected.length).toBeGreaterThan(10);
      expect(entry.wrong.length).toBeGreaterThan(10);
      // An entry with no scenario is a hole, and says so.
      if (!entry.scenario) expect(entry.open ?? "").not.toBe("");
    }
  });
});

describe("chat simulator map: each case does what the map expects", () => {
  for (const entry of MAP) {
    if (!entry.scenario || !entry.check) continue;
    // A known hole fails today: when it starts passing, take its `open` away.
    const it = entry.open ? test.failing : test;
    it(`${entry.id}: ${entry.expected}`, () => {
      expect(entry.check!(run(entry.scenario!))).toEqual([]);
    });
  }
});

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

describe("chat simulator map: what every chat keeps", () => {
  for (const name of Object.keys(SCENARIOS))
    for (const each of EVERYWHERE) {
      // A scenario known to break a check fails it today: when it passes, take it out of `known`.
      const it = each.known?.[name] ? test.failing : test;
      it(`${name}: ${each.id}${each.known?.[name] ? ` (open: ${each.known[name]})` : ""}`, () => {
        expect(each.check(run(name))).toEqual([]);
      });
    }

  for (const name of Object.keys(SCENARIOS)) {
    test(`${name}, read from halfway (a reconnect): the rules and the everywhere checks`, () => {
      const result = fromHalfway(name);
      expect(rules(result).filter((line) => line.startsWith("b-"))).toEqual([]);
      for (const each of EVERYWHERE)
        if (!each.known?.[name]) expect({ [each.id]: each.check(result) }).toEqual({ [each.id]: [] });
    });
    test(`${name}, on a narrow pane (320): rules a and b`, () => {
      expect(rules(runSimulation(SCENARIOS[name]!(), { width: 320 }))).toEqual([]);
    });
  }
});
