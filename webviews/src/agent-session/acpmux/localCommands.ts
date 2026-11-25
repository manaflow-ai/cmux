import { agentKey } from "../shared/agentKey";
import type { SessionInfoSectionId } from "./session-info/sessionInfoState";

/// Slash commands a harness answers on its own, without a model turn: they read or show state and
/// send nothing to the model. Typed alone, the composer runs them at once, in the GUI, even mid-turn:
/// never queued, steered or held behind the running turn (Leo, 2026-11-10: "typing /mcp or /status
/// on its own should NOT queue/steer and wait behind... at least for these types of nonsending type
/// messages, they should just... go there. and run. instead of being treated like normal messages").
///
/// Sent to the harness, such a command would wait anyway: Claude Code holds a command until the turn
/// it runs ends (cliOnlyCommands.ts `commandWaitsForTurn`), and over ACP it answers its terminal menus
/// (/mcp, /cost) only with "isn't available in this environment". So each one is cmux's GUI answer
/// to the same question.
///
/// This is the one list, per harness, since harnesses differ. A command that changes the turn or
/// sends to the model (/compact, /clear, /init, /review, /plan with a prompt) is never here and keeps
/// the normal path. cmux's own commands (cmuxCommands.ts: /status, /context, bare /model) are local
/// too and already run at once; they win over this list, so a cmux command that grows (/mcp with
/// subcommands) takes over its name. A command with arguments is the harness's (`/model opus`).
export type LocalCommandAction =
  /// Opens Session Info on this section.
  | { kind: "section"; section: SessionInfoSectionId }
  /// Opens the `/` menu, every command and skill with its description: the GUI's help.
  | { kind: "commands" }
  /// Opens the chat's working-tree changes beside it (the Changes tab), as `/diff` shows them.
  | { kind: "changes" };

/// Session Info's sections a command opens, by harness (agentKey). Semantics are each harness's own:
/// Claude Code (`claude` 2.1, its built-in commands of type `local` / `local-jsx`):
///   /mcp lists MCP servers and their state; /cost the session's spend; /usage the plan's limits;
///   /help the commands. /status, /context and /model are cmux's own already.
/// Codex (codex-rs tui `SlashCommand`, those `available_during_task` that never submit a turn):
///   /mcp lists the configured MCP tools; /diff shows the git diff (untracked files too); /usage the
///   account's limits; /skills the skills. /status is cmux's own already. /ps (background
///   terminals) is left to Codex: Session Info draws no Background tasks section while nothing
///   runs. /init, /compact, /review and /plan submit to the model and are not available during a
///   task, so they stay out.
const LOCAL: Readonly<Record<string, Readonly<Record<string, LocalCommandAction>>>> = {
  claude: {
    mcp: { kind: "section", section: "connectors" },
    cost: { kind: "section", section: "usage" },
    usage: { kind: "section", section: "usage" },
    help: { kind: "commands" },
  },
  codex: {
    mcp: { kind: "section", section: "connectors" },
    diff: { kind: "changes" },
    usage: { kind: "section", section: "usage" },
    skills: { kind: "commands" },
  },
};

export type LocalCommand = { name: string; action: LocalCommandAction };

/// The local command `prompt` is for this harness, typed alone (no arguments, no other words);
/// undefined for anything else, which keeps the normal send path.
export function localCommand(prompt: string, harness: string | undefined): LocalCommand | undefined {
  const table = LOCAL[agentKey(harness) ?? ""];
  if (!table) return undefined;
  // The composer's text is Markdown with typed characters escaped; a bare command has none.
  const name = /^\/([a-z][\w-]*)$/i.exec(prompt.trim())?.[1]?.toLowerCase();
  if (!name || !Object.hasOwn(table, name)) return undefined;
  return { name, action: table[name]! };
}

/// The names that are local for this harness (tests and the gallery).
export function localCommandNames(harness: string | undefined): readonly string[] {
  return Object.keys(LOCAL[agentKey(harness) ?? ""] ?? {});
}
