// Each subagent's color comes from its id alone (agentTones.ts): the same agent reads the same in
// the agents list, the transcript, a reload, older history loaded later and a pane of its own.
import { describe, expect, test } from "bun:test";
import { AGENT_TONES, agentTone, agentTones } from "../src/agent-session/acpmux/subagents/agentTones";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";

const agent = (id: string, startedAt: number) => ({ id, name: id, startedAt, state: "running" }) as Subagent;

describe("agent tones", () => {
  test("an agent's tone depends on its id only, not on the other agents or their order", () => {
    const alone = agentTones([agent("x", 1)]);
    const crowd = agentTones([agent("z", 0), agent("y", 2), agent("x", 1)]);
    expect(crowd.get("x")).toBe(alone.get("x")!);
    expect(crowd.get("x")).toBe(agentTone("x"));
  });

  test("ids spread over every tone", () => {
    const tones = new Set(Array.from({ length: 200 }, (_, index) => agentTone(`toolu_${index}`)));
    expect([...tones].sort((a, b) => a - b)).toEqual(Array.from({ length: AGENT_TONES }, (_, tone) => tone));
  });
});
