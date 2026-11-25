import { agentKey } from "../shared/agentKey";

/// Claude Code slash commands that need its terminal UI. Sent through acpmux, Claude Code answers
/// them only with "isn't available in this environment" (2.1.299), and before acpmux ended such a
/// turn they left the chat running (cosmic-gray, 2026-10-14). The composer keeps them and names
/// the cmux control that does the job instead.

/// What to use instead: the access menu, the model picker, or nothing in cmux.
export type CliOnlyUse = "access" | "model" | "terminal";

/// Any form of these needs the terminal.
const ALWAYS: Record<string, CliOnlyUse> = {
  permissions: "access",
  "allowed-tools": "access",
  logout: "terminal",
  doctor: "terminal",
  "terminal-setup": "terminal",
  vim: "terminal",
  theme: "terminal",
  ide: "terminal",
  statusline: "terminal",
  "privacy-settings": "terminal",
  color: "terminal",
  focus: "terminal",
  exit: "terminal",
  quit: "terminal",
};

/// `/config key=value` still needs the terminal. `/model`, `/resume` and `/login` are cmux GUI
/// commands (cmuxCommands.ts); the composer handles them instead.
const BARE: Record<string, CliOnlyUse> = { config: "terminal" };

/// The terminal-only command `prompt` is, for a Claude chat; undefined otherwise.
export function cliOnlyCommand(
  prompt: string,
  harness: string | undefined,
): { name: string; use: CliOnlyUse } | undefined {
  // Variants ("claude-sr") run the same Claude Code.
  if (agentKey(harness) !== "claude") return undefined;
  const match = /^\/([a-z][\w-]*)(\s+[\s\S]*)?$/i.exec(prompt.trim());
  if (!match) return undefined;
  const name = match[1].toLowerCase();
  const use = Object.hasOwn(ALWAYS, name)
    ? ALWAYS[name]
    : !match[2]?.trim() && Object.hasOwn(BARE, name)
      ? BARE[name]
      : undefined;
  return use ? { name, use } : undefined;
}

/// Whether `prompt` is one of the agent's own slash commands (`commands`, its
/// `available_commands_update`: built-ins, skills and plugin commands such as `/loop`), for a
/// Claude chat. Claude Code never reads a command into a running turn: it holds the line until the
/// command it is running ends (its `command_lifecycle` stays `queued`), so a `/loop` steered into
/// a busy turn sat under it as an unread steer with Send now until that work was done (Leo,
/// 2026-10-31: "the commands don't work!"). Such a prompt queues instead, and runs as its own turn
/// with its own reply when this one ends. Text that only starts with a slash (a path, a word the
/// agent does not list) is the agent's to read, and steers as before.
export function commandWaitsForTurn(
  prompt: string,
  harness: string | undefined,
  commands: readonly { name: string; source?: string }[] | undefined,
): boolean {
  if (agentKey(harness) !== "claude" || !commands?.length) return false;
  // The composer's text is Markdown with typed characters escaped (`/mcp\_\_github\_\_list`).
  const name = /^\/(\S+)(?:\s|$)/
    .exec(prompt.trim())?.[1]
    ?.replace(/\\([!-/:-@[-`{-~])/g, "$1")
    .toLowerCase();
  // cmux's own commands (cmuxCommands.ts) share the menu's list; their passthrough forms
  // (`/model opus`, `/plan explain`) keep the send they had.
  return (
    name !== undefined && commands.some((command) => command.source !== "cmux" && command.name.toLowerCase() === name)
  );
}
