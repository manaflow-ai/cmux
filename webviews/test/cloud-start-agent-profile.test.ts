// A Cloud machine carries Claude Code, Codex, OpenCode and pi (web/services/vms/images/agents.ts), never
// this Mac's own harness profiles. A composer on a profile that routes Claude Code or Codex its own way
// (claude-sr2, a ~/.config/cmux/harnesses file) sent that id to the machine, which refused the start as
// `agent_session.harness_missing` ("Claude (SR2) isn't installed on lease-…", cmux#51731).
import { expect, test } from "bun:test";

import { cloudSendAgent } from "../src/agent-session/acpmux/cloudModePick";
import { cloudStartAgent } from "../src/agent-session/acpmux/harnessModes";

test("a Mac-only Claude Code or Codex profile starts its base agent on the Cloud machine", () => {
  for (const [family, harness, runs] of [
    ["claude-sr2", "claude-sr2", "claude"],
    ["claude", "claude-sr2", "claude"],
    [undefined, "claude-cr", "claude"],
    ["codex", "codex-acp", "codex"],
    ["codex-cr", "codex-cr", "codex"],
  ] as const) {
    expect(cloudStartAgent(family, harness)).toEqual({ family: runs, harness: runs, named: true });
    // The model the composer shows still goes: the base agent runs the same model.
    expect(cloudSendAgent(family, harness, "claude-opus-5-5")).toEqual({ harness: runs, model: "claude-opus-5-5" });
  }
});

test("an agent the machine carries is named as is, and UniiChat still leaves the machine's default", () => {
  for (const agent of ["claude", "codex", "opencode", "pi"])
    expect(cloudStartAgent(agent, agent)).toEqual({ family: agent, harness: agent, named: true });
  expect(cloudStartAgent("unii", "unii")).toEqual({ family: "claude", harness: "claude", named: false });
  expect(cloudSendAgent("unii", "unii", "m")).toEqual({});
});
