// A message to a subagent from its own pane (SubagentComposer.tsx). Leo, 2026-11-03: "are claude
// code subagents truly forced to be read only? you can't directly send to them?" and "currently it
// says "read only" on the subagents in cmux-next. we should improve that".
//
// A subagent shown in a pane (subagents/subagentPanes.ts) has no acpmux session of its own: Claude
// Code's Agent subagents, Codex's collaboration agents and a Claude workflow's agents all run inside
// the chat's turn, and acpmux has no op that prompts one. Only the chat's agent can reach them
// (Claude Code's SendMessage, which also resumes a finished one; Codex's agent messaging tools). So
// the pane's prompt goes to the chat, the subagent's parent, as a relay that names the subagent by
// the id its harness knows it by, and the composer says so: its placeholder names the subagent, and
// the line under it names the chat that passes it on. Nothing is ever sent to a target the composer
// does not name. A started chat (an acpmux sub-session) has a session of its own and opens as its own
// chat with its own composer; it never reaches this relay.
import type { Translate } from "../i18n";
import type { Subagent } from "./subagentFold";

/// Who a subagent pane's prompt is for: the subagent as the pane names it, the id its parent's
/// harness reaches it by, and whether that harness is Claude Code (SendMessage).
export type SubagentTarget = {
  name: string;
  id?: string;
  claude: boolean;
};

/// Whether `family` is harness `base` or one of its profiles (`claude-sr2`, `codex_work`), as the mode
/// menu reads it (harnessModes.ts `familyMenu`).
function isHarness(family: string | undefined, base: "claude" | "codex"): boolean {
  const id = (family ?? "").toLowerCase();
  return id === base || id.startsWith(`${base}-`) || id.startsWith(`${base}_`);
}

/// The target for a subagent of a chat whose harness family is `family` (`claude`, `codex`, or a
/// profile of one, `claude-sr2`). Claude Code reaches a subagent by the agentId its Agent call
/// answered with; Codex by the agent's thread id, which is its subagent id in acpmux's records
/// (cmux-tui acpmux `subagents.rs`).
export function subagentTarget(
  agent: Pick<Subagent, "id" | "name" | "task" | "agentId">,
  family: string | undefined,
): SubagentTarget {
  const claude = isHarness(family, "claude");
  const name = agent.task ?? agent.name;
  const id = claude ? agent.agentId : isHarness(family, "codex") ? agent.id : agent.agentId;
  return { name, claude, ...(id ? { id } : {}) };
}

/// A Claude workflow's agent (workflowAgents.ts): its label and Claude's agentId for it.
export function workflowAgentTarget(agent: { label?: string; agentId?: string }, fallback: string): SubagentTarget {
  return { name: agent.label || fallback, claude: false, ...(agent.agentId ? { id: agent.agentId } : {}) };
}

/// The prompt the chat's agent gets for `message` to `target`: the message kept as typed on the
/// lines after the instruction, as Restart keeps a subagent's prompt (restart.ts).
export function subagentRelayPrompt(target: SubagentTarget, message: string, t: Translate): string {
  const values = { name: target.name, message, ...(target.id ? { id: target.id } : {}) };
  if (target.claude) return target.id ? t("subagents.relayClaudeId", values) : t("subagents.relayClaude", values);
  return target.id ? t("subagents.relayId", values) : t("subagents.relay", values);
}

/// Whether the relay to a subagent goes in as a steer: only while the chat's turn runs and its agent
/// steers, as the chat's composer decides (Composer.tsx `steers`). Otherwise it is a prompt of its
/// own: Claude Code refuses a steer with no turn running, the usual state once the subagent is done.
export function subagentRelaySteers(chat: { isWorking: boolean; summary?: { steering?: boolean } }): boolean {
  return chat.isWorking && chat.summary?.steering === true;
}
