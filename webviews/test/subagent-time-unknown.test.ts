// l10n-allow-file: subagent fixtures.
// A subagent's time comes from its real start and end; unknown, it shows none (Leo, 2026-11-22, on a
// card reading "Disconnected · 0s" after a restart: "and more bullshit somehow happened here").
import { expect, test } from "bun:test";
import { subagentTime } from "../src/agent-session/acpmux/subagents/subagentGroupModel";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";

const helper = (fields: Partial<Subagent> = {}): Subagent => ({
  id: "helper",
  parent: null,
  name: "Helper",
  state: "completed",
  startedAt: 1_000,
  endedAt: 61_000,
  ...fields,
});

test("an ended subagent whose start and end are one moment has no time, never 0s", () => {
  expect(subagentTime(helper({ state: "disconnected", startedAt: 5_000, endedAt: 5_000 }), 99_000)).toBeUndefined();
  expect(subagentTime(helper(), 99_000)).toBe("1m");
  expect(subagentTime(helper({ state: "running", startedAt: 99_000, endedAt: undefined }), 99_000)).toBe("0s");
});
