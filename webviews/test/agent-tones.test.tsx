// Each subagent's color (agentTones.ts). Leo, 2026-11-04: "Each subagent gets its own colour (medium).
// Today three Claude subagents look identical. Keep the harness mark and add a stable colour per
// subagent, used everywhere it shows." The chat assigns its agents' tones together, so siblings never
// share one while there are tones to go round, and `agentTone(id)` then answers the same tone to every
// surface: the agents list, the transcript, the tray, Session Info and the agent's own pane.
import { beforeEach, describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AgentIdentity } from "../src/agent-session/acpmux/subagents/AgentIdentity";
import {
  AGENT_TONES,
  agentTone,
  agentTones,
  hashTone,
  resetAgentTones,
} from "../src/agent-session/acpmux/subagents/agentTones";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";

const agent = (id: string, startedAt: number) =>
  ({ id, name: id, startedAt, state: "running", parent: null, harness: "claude" }) as Subagent;

// Three Claude subagents whose ids all hash to the same tone: the case that used to look identical.
const CLASHING = ["agent-review-rendering", "agent-check-tokens", "agent-read-theme"];

beforeEach(() => resetAgentTones());

describe("agent tones", () => {
  test("the fixture's three ids share one hash tone", () => {
    expect(new Set(CLASHING.map(hashTone)).size).toBe(1);
  });

  test("three Claude subagents whose ids hash alike get three different tones", () => {
    const tones = agentTones(CLASHING.map((id, index) => agent(id, index)));
    expect(new Set(tones.values()).size).toBe(3);
    // The first keeps its hash's tone; only the later ones move.
    expect(tones.get(CLASHING[0]!)).toBe(hashTone(CLASHING[0]!));
  });

  test("every surface reads the chat's tone for an agent, not the bare hash", () => {
    const tones = agentTones(CLASHING.map((id, index) => agent(id, index)));
    const marks = CLASHING.map((id) => {
      expect(agentTone(id)).toBe(tones.get(id)!);
      // What a row draws from it: the identity mark in that tone.
      const html = renderToStaticMarkup(<AgentIdentity tone={agentTone(id)} size={14} />);
      expect(html).toContain(`data-agent-tone="${tones.get(id)}"`);
      return html;
    });
    expect(new Set(marks).size).toBe(3);
  });

  test("an agent keeps its tone as others start, end and older ones load", () => {
    const first = agentTones([agent(CLASHING[1]!, 10), agent(CLASHING[2]!, 20)]);
    // A new agent starts, and older history brings in one that started before both.
    const later = agentTones([
      agent(CLASHING[0]!, 0),
      agent(CLASHING[1]!, 10),
      agent(CLASHING[2]!, 20),
      agent("agent-new", 30),
    ]);
    expect(later.get(CLASHING[1]!)).toBe(first.get(CLASHING[1]!)!);
    expect(later.get(CLASHING[2]!)).toBe(first.get(CLASHING[2]!)!);
    expect(new Set(later.values()).size).toBe(4);
    // One ends and drops out of the list: the rest keep theirs.
    const after = agentTones([agent(CLASHING[2]!, 20)]);
    expect(after.get(CLASHING[2]!)).toBe(first.get(CLASHING[2]!)!);
  });

  test("the same chat gets the same tones after a reload, whatever order the list arrives in", () => {
    const agents = [...CLASHING, "agent-explore-layout", "agent-audit-spacing"].map((id, index) => agent(id, index));
    const before = agentTones(agents);
    resetAgentTones();
    const reloaded = agentTones([...agents].reverse());
    expect(Object.fromEntries(reloaded)).toEqual(Object.fromEntries(before));
    expect(new Set(before.values()).size).toBe(AGENT_TONES);
  });

  test("past the tone count, tones spread evenly", () => {
    const tones = agentTones(Array.from({ length: 12 }, (_, index) => agent(`toolu_${index}`, index)));
    const counts = Array.from({ length: AGENT_TONES }, () => 0);
    for (const tone of tones.values()) counts[tone]++;
    expect(Math.max(...counts) - Math.min(...counts)).toBeLessThanOrEqual(1);
  });

  test("ids spread over every tone", () => {
    const tones = new Set(Array.from({ length: 200 }, (_, index) => hashTone(`toolu_${index}`)));
    expect([...tones].sort((a, b) => a - b)).toEqual(Array.from({ length: AGENT_TONES }, (_, tone) => tone));
  });
});
