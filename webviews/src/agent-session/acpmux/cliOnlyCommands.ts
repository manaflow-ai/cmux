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
  login: "terminal",
  logout: "terminal",
  doctor: "terminal",
  "terminal-setup": "terminal",
  vim: "terminal",
  theme: "terminal",
  resume: "terminal",
  ide: "terminal",
  statusline: "terminal",
  "privacy-settings": "terminal",
  color: "terminal",
  focus: "terminal",
  exit: "terminal",
  quit: "terminal",
};

/// `/config key=value` still needs the terminal. `/model` is a cmux GUI command and is handled by
/// the composer before this guard can reject it.
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
