// l10n-allow-file: test fixture subagent names, not shipped UI.
// The agents pill's list puts a nested agent right under the agent that spawned it, keeping the
// section's order (subagents/AgentsPill.tsx `nestAgents`).
import { describe, expect, test } from "bun:test";
import { nestAgents } from "../src/agent-session/acpmux/subagents/AgentsPill";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";

const agent = (id: string, parent: string | null = null): Subagent => ({
  id,
  parent,
  name: id,
  state: "running",
  startedAt: 0,
});
const rows = (agents: Subagent[]) => nestAgents(agents).map(({ agent, depth }) => `${agent.id}:${depth}`);

describe("nestAgents", () => {
  test("children sit under their parent, a level per generation, siblings in section order", () => {
    expect(rows([agent("a"), agent("b"), agent("c", "a"), agent("d", "c"), agent("e", "a")])).toEqual([
      "a:0",
      "c:1",
      "d:2",
      "e:1",
      "b:0",
    ]);
  });

  test("a child listed before its parent still lands under it", () => {
    expect(rows([agent("c", "a"), agent("a")])).toEqual(["a:0", "c:1"]);
  });

  test("an agent whose parent is not in the section stays at the top level", () => {
    expect(rows([agent("c", "elsewhere"), agent("b")])).toEqual(["c:0", "b:0"]);
  });

  test("a parent loop or a self-parent lists the agents flat rather than dropping them", () => {
    expect(rows([agent("a", "b"), agent("b", "a"), agent("s", "s"), agent("r")])).toEqual(["r:0", "a:0", "b:0", "s:0"]);
  });
});
