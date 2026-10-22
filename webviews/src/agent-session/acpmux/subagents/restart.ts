// Restart for a subagent that ended without finishing (SubagentDoneLine.tsx). Neither acpmux nor
// Claude Code has an op that runs a stopped subagent again, so Restart takes the path the person
// would: it sends the chat a prompt that asks its agent to run that subagent again, with its kind
// and the prompt it was given (acpmux's `subagent_spawned` `prompt`, Claude's Agent input), through
// the composer's own send (App.tsx `chat.send`, as Retry does). Only the chat's own subagents
// restart (a nested one is its parent subagent's to run), and only one whose prompt acpmux
// recorded.
import type { StringKey, Translate } from "../i18n";
import type { Subagent, SubagentStopReason } from "./subagentFold";

/// The short reason a stopped subagent's line adds (subagentFold.ts `stopReasonOf`).
export const STOP_REASON_LABEL: Record<SubagentStopReason, StringKey> = {
  user: "subagents.stopReason.user",
  sendNow: "subagents.stopReason.sendNow",
};

/// Whether `agent`'s line offers Restart: it ended without finishing (stopped, failed or lost),
/// is the chat's own, and its prompt is known.
export function canRestart(agent: Pick<Subagent, "state" | "parent" | "prompt">): boolean {
  return agent.state !== "running" && agent.state !== "completed" && agent.parent === null && Boolean(agent.prompt);
}

/// The prompt Restart sends the chat for `agent`, or undefined when it cannot restart.
export function restartPrompt(agent: Pick<Subagent, "state" | "parent" | "prompt" | "name" | "kind">, t: Translate) {
  if (!canRestart(agent)) return undefined;
  const values = { name: agent.name, prompt: agent.prompt! };
  return agent.kind
    ? t("subagents.restartPromptKind", { ...values, kind: agent.kind })
    : t("subagents.restartPrompt", values);
}

/// What decides whether the shown chat offers Restart at all, as its composer would send.
export type RestartChat = {
  connected: boolean;
  sessionId: string | undefined;
  /// View Only: the composer takes the chat over before anything is sent.
  watching: boolean;
  /// A subagent's own read-only pane.
  readOnly: boolean;
  /// remoteEditing.ts `remoteComposer(...).canSend`: false for a remote Codex or opencode chat.
  canSend: boolean;
};

/// The chat Restart's rows send to, or undefined when the shown chat offers no Restart.
export function restartOwner(chat: RestartChat): string | undefined {
  return chat.connected && !chat.watching && !chat.readOnly && chat.canSend ? chat.sessionId : undefined;
}

/// Whether a Restart from a row drawn for `owner` still reaches that chat: the pane still shows it
/// (`shown`) and the client, which `chat.send` writes to, still has it selected (`selected`). During
/// a switch's hold the pane draws the chat before while the client already names the next one.
export function restartReaches(owner: string, shown: string | undefined, selected: string | undefined): boolean {
  return owner === shown && owner === selected;
}
