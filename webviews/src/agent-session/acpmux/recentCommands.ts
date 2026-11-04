// The slash commands and skills the person picked last, for the + menu's few recent rows (Leo,
// 2026-11-01: "our + button results are still really bad"). The + menu lists at most
// PLUS_RECENT_COMMANDS of them; every other command and skill stays under / (the slash list, which
// the + menu's "Commands and skills…" row opens). Local UI memory, never sent to the host.
import type { SlashCommand } from "./slashCommands";

const RECENT_COMMANDS_KEY = "cmux.acpmux.recentSlashCommands";
/// How many names are kept: more than the menu shows, so a command the next chat's agent doesn't
/// advertise doesn't push out the ones it does.
const RECENT_COMMANDS_LIMIT = 12;
/// How many recent commands the + menu lists, at most.
export const PLUS_RECENT_COMMANDS = 3;

export function loadRecentCommandNames(): string[] {
  try {
    const value: unknown = JSON.parse(globalThis.localStorage?.getItem(RECENT_COMMANDS_KEY) ?? "[]");
    if (!Array.isArray(value)) return [];
    return value
      .filter((name): name is string => typeof name === "string" && name.length > 0)
      .slice(0, RECENT_COMMANDS_LIMIT);
  } catch {
    return [];
  }
}

/// Puts `name` first in the kept list and returns the new list.
export function rememberRecentCommand(name: string): string[] {
  const next = [name, ...loadRecentCommandNames().filter((entry) => entry !== name)].slice(0, RECENT_COMMANDS_LIMIT);
  try {
    globalThis.localStorage?.setItem(RECENT_COMMANDS_KEY, JSON.stringify(next));
  } catch {
    // Private windows and blocked storage keep the menu working without recents.
  }
  return next;
}

/// The kept names this chat's agent advertises, most recent first, at most PLUS_RECENT_COMMANDS.
/// Goal has its own + row, so it is never a recent one.
export function recentCommands(
  names: readonly string[],
  commands: readonly SlashCommand[] | undefined,
): SlashCommand[] {
  if (!commands?.length) return [];
  const byName = new Map(commands.map((command) => [command.name, command]));
  const picked: SlashCommand[] = [];
  for (const name of names) {
    const command = byName.get(name);
    if (!command || command.name.toLowerCase() === "goal" || picked.includes(command)) continue;
    picked.push(command);
    if (picked.length === PLUS_RECENT_COMMANDS) break;
  }
  return picked;
}
