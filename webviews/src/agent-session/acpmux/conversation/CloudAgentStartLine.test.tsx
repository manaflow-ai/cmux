import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AGENT_START_SLOW_MS, agentStartStage } from "../cloudStartViewModel";
import { CloudAgentStartLine } from "./CloudAgentStartLine";

describe("agentStartStage", () => {
  test("names the agent and the usual wait", () => {
    const stage = agentStartStage("Claude Code", 1_000, 5_000);
    expect(stage.label).toBe("Starting Claude Code");
    expect(stage.detail).toBeUndefined();
    expect(stage.since).toBe(1_000);
  });
  test("says it is taking longer past the slow mark", () => {
    expect(agentStartStage("Codex", 0, AGENT_START_SLOW_MS - 1).detail).toBeUndefined();
    expect(agentStartStage("Codex", 0, AGENT_START_SLOW_MS).detail).toBe("taking longer than usual");
  });
  test("with no start time keeps the usual wait", () => {
    expect(agentStartStage("Codex", undefined, 10 * AGENT_START_SLOW_MS).detail).toBeUndefined();
  });
});

describe("CloudAgentStartLine", () => {
  test("draws one live line with the agent, its clock and the wait, and no Cancel", () => {
    const html = renderToStaticMarkup(<CloudAgentStartLine agent="Claude Code" since={Date.now() - 5_000} below />);
    expect(html).toContain("Starting Claude Code");
    expect(html).not.toContain("usually");
    expect(html).toContain("cv-worked cv-worked--live acpmux-cloud-start__agent is-below");
    expect(html).toContain("cv-worked__time");
    expect(html).not.toContain("Cancel");
    expect(html).not.toContain("<button");
  });
});
