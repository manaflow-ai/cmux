// Each subagent keeps one color for the life of the chat (agentTones.ts). A new agent takes a
// color no running agent has while one is free, so two agents running at once never share one,
// and an agent's color never changes as others start and end.
import { describe, expect, test } from "bun:test";
import { AGENT_TONES, agentTones } from "../src/agent-session/acpmux/subagents/agentTones";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";

const agent = (id: string, startedAt: number, state = "running") => ({ id, name: id, startedAt, state }) as Subagent;

describe("agent tones", () => {
  test("agents running at once get distinct colors while one is free", () => {
    const first = Array.from({ length: AGENT_TONES }, (_, index) => agent(`a${index}`, index));
    const before = agentTones("reuse", first);
    expect(new Set(before.values()).size).toBe(AGENT_TONES);
    // All but the first end; a new agent starts while the first still runs.
    const later = [first[0]!, ...first.slice(1).map((done) => ({ ...done, state: "completed" })), agent("late", 99)];
    const after = agentTones("reuse", later);
    for (const done of first) expect(after.get(done.id)).toBe(before.get(done.id)!);
    expect(after.get("late")).not.toBe(after.get("a0")!);
  });

  test("a chat's colors hold as agents start", () => {
    const one = agentTones("hold", [agent("x", 1), agent("y", 2)]);
    const two = agentTones("hold", [agent("x", 1), agent("y", 2), agent("z", 3)]);
    expect([two.get("x"), two.get("y")]).toEqual([one.get("x"), one.get("y")]);
    expect(two.get("z")).not.toBe(two.get("x")!);
    expect(two.get("z")).not.toBe(two.get("y")!);
  });
});
