// A subagent the person stopped (cancelled) or one acpmux lost (disconnected) read "Failed", in red,
// in the agents pill and the summary card's list, while its transcript row said "Cancelled" or
// "Disconnected". Those lists now call it stopped: its own state's label, without the failure color.
import { expect, test } from "bun:test";
import { subagentStatus, subagentStatusLabel } from "../src/agent-session/acpmux/summary/SubagentStatusList";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";

const agent = (state: string): Subagent => ({ id: state, parent: null, name: state, state, startedAt: 0, endedAt: 1 });
const none = new Set<string>();

test("a cancelled or disconnected subagent is stopped, with its own state's label", () => {
  expect(subagentStatus(agent("cancelled"), none)).toBe("stopped");
  expect(subagentStatus(agent("disconnected"), none)).toBe("stopped");
  expect(subagentStatusLabel(agent("cancelled"), none)).toBe("subagents.state.cancelled");
  expect(subagentStatusLabel(agent("disconnected"), none)).toBe("subagents.state.disconnected");
});

test("done, failed, running and waiting keep their labels", () => {
  expect(subagentStatusLabel(agent("completed"), none)).toBe("subagents.state.completed");
  expect(subagentStatusLabel(agent("failed"), none)).toBe("subagents.state.failed");
  expect(subagentStatusLabel({ ...agent("running"), endedAt: undefined }, none)).toBe("subagents.state.running");
  expect(subagentStatusLabel({ ...agent("running"), endedAt: undefined }, new Set(["running"]))).toBe(
    "subagents.state.waiting",
  );
});
