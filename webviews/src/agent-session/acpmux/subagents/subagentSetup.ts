// What a subagent was started with: its model, effort and permission mode, one line on its hover
// card (SubagentPreview.tsx). Leo, 2026-11-22: "so for subagents, actually, are their
// permissions/model locked right then and there? does it make sense to be able to reveal the fork
// or whatever switching model behaviour for it?" A harness's own subagent (Claude's Agent call,
// Codex's spawn) takes its model at spawn and runs its tool calls under its chat's permission mode;
// nothing switches either afterwards, so the card says them rather than offering a picker.
import { harnessFamilyMenu } from "../harnessModes";
import type { Subagent } from "./subagentFold";

/// The harness's own name for `modeId` ("Plan", "Bypass permissions"), else the id as reported.
export function subagentModeName(modeId: string, harness = "claude"): string {
  return harnessFamilyMenu(harness, harness)?.rows.find((row) => row.id === modeId)?.name ?? modeId;
}

/// "claude-haiku-4-5 · high · Plan", or undefined when the harness reported none of them.
export function subagentSetup(
  agent: Pick<Subagent, "model" | "effort" | "permissionMode" | "harness">,
): string | undefined {
  const effort = agent.effort && agent.effort !== "default" ? agent.effort : undefined;
  const mode = agent.permissionMode ? subagentModeName(agent.permissionMode, agent.harness ?? "claude") : undefined;
  const parts = [agent.model, effort, mode].filter(Boolean);
  return parts.length > 0 ? parts.join(" · ") : undefined;
}
