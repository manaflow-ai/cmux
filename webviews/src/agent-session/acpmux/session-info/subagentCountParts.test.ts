// Every subagent count line reads in one order (subagentsSectionModel.ts `SUBAGENT_COUNT_ORDER`):
// waiting, failed, running, queued, idle, stopped, done. At 420 px the Session Info head read
// "1 waiting · 4 running · 1 faile…": the failure, the one other thing that needs the person, was the
// part the ellipsis cut (cmuxterm-hq#19495).
import { expect, test } from "bun:test";
import { translate } from "../i18n";
import { SUBAGENT_COUNT_ORDER, orderedCountParts, orderedCountWords, subagentCounts } from "./subagentsSectionModel";
import type { Subagent } from "../subagents/subagentFold";

test("the order: waiting, failed, running, queued, idle, stopped, done", () => {
  expect(SUBAGENT_COUNT_ORDER).toEqual(["waiting", "failed", "running", "queued", "idle", "stopped", "done"]);
  expect(
    orderedCountWords({ done: 40, stopped: 2, idle: 1, queued: 3, running: 4, failed: 1, waiting: 1 }, translate),
  ).toEqual(["1 waiting", "1 failed", "4 running", "3 queued", "1 idle", "2 stopped", "40 done"]);
});

test("the running ones are their mark and number; hover and VoiceOver keep the word", () => {
  expect(orderedCountParts({ running: 4, failed: 1, waiting: 1 }, translate)).toEqual([
    "1 waiting",
    "1 failed",
    { live: 4, label: "4 running" },
  ]);
});

test("a zero or missing count says nothing", () => {
  expect(orderedCountWords({ waiting: 0, running: 2 }, translate)).toEqual(["2 running"]);
  expect(orderedCountParts({}, translate)).toEqual([]);
});

test("a surface's own words keep its place in the order; parts after a kind follow it", () => {
  expect(
    orderedCountParts({ running: 1, done: 3 }, translate, {
      words: { running: () => "Working" },
      after: { running: ["2 commands", false] },
    }),
  ).toEqual(["Working", "2 commands", "3 done"]);
  // An `after` part shows with its kind at zero too.
  expect(orderedCountParts({ failed: 1 }, translate, { after: { running: ["2 commands"] } })).toEqual([
    "1 failed",
    "2 commands",
  ]);
});

test("the Session Info head names the failure right after what waits", () => {
  const agent = (id: string, state: Subagent["state"]) => ({ id, state, title: id }) as unknown as Subagent;
  const agents = [
    agent("w", "running"),
    agent("a", "running"),
    agent("b", "running"),
    agent("c", "running"),
    agent("d", "running"),
    agent("f", "failed"),
  ];
  expect(subagentCounts(translate, agents, new Set(["w"]))).toBe("1 waiting · 1 failed · 4 running");
});
