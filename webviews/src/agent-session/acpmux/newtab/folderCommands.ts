// The New Tab's `/` menu lists its agent's commands for the page's folder from a deferred chat, which
// answers only once the agent has started (Claude Code with many plugins: 5 to 12 s). Until then the
// menu lists what the person's newest chat of that agent in that folder listed: acpmux keeps each
// chat's last list, and every page can read it (`sessionCommands`), unlike the page's own memory,
// which a New Tab (a new page) starts without.
import type { SlashCommand } from "../slashCommands";
import { shownName } from "../slashCommands";
import type { AcpmuxSessionEntry } from "../sessionList";
import { intl } from "../../../ui/intl";

/// How many of the newest chats are tried for a list, the newest first.
const MAX_CHATS = 3;

/// The person's newest chats on this Mac of `harness` in `folder` (at most three, the newest first),
/// whose command list stands in for the deferred chat's until that one answers. One pass over the
/// list, no sort of it.
export function folderChats(
  sessions: readonly Pick<AcpmuxSessionEntry, "sessionId" | "harness" | "cwd" | "updatedAt" | "peer">[],
  harness: string | undefined,
  folder: string | undefined,
): string[] {
  if (!harness || !folder) return [];
  const newest: { sessionId: string; updatedAt: number }[] = [];
  for (const session of sessions) {
    if (session.peer || session.harness !== harness || session.cwd !== folder) continue;
    const updatedAt = session.updatedAt ?? 0;
    const at = newest.findIndex((kept) => updatedAt > kept.updatedAt);
    if (at < 0) {
      if (newest.length < MAX_CHATS) newest.push({ sessionId: session.sessionId, updatedAt });
      continue;
    }
    newest.splice(at, 0, { sessionId: session.sessionId, updatedAt });
    if (newest.length > MAX_CHATS) newest.pop();
  }
  return newest.map((kept) => kept.sessionId);
}

/// The agent's own commands: its skills, prompts and built-ins, not cmux's, an extension's or a saved prompt.
const agentsOwn = (command: SlashCommand) =>
  command.source === "agent" || command.source === "skill" || command.source === "prompt";

/// `listed` with `kept` (another chat's list) after it, while `listed` has none of the agent's own
/// (the deferred chat has not answered yet); else `listed`.
export function withFolderCommands(
  listed: readonly SlashCommand[],
  kept: readonly SlashCommand[] | undefined,
): readonly SlashCommand[] {
  if (!kept?.length || listed.some(agentsOwn)) return listed;
  return [...listed, ...kept.filter(agentsOwn)];
}

/// The menu's order (Lucas 2026-11-25): the skills and prompts first, A to Z by the name the menu
/// shows, then every other command in its own order.
export function skillsFirst(commands: readonly SlashCommand[]): SlashCommand[] {
  const skills = commands.filter((command) => command.source === "skill" || command.source === "prompt");
  if (skills.length === 0) return [...commands];
  const byName = intl.Collator(undefined, { sensitivity: "base", numeric: true });
  skills.sort((a, b) => byName.compare(shownName(a), shownName(b)));
  return [...skills, ...commands.filter((command) => command.source !== "skill" && command.source !== "prompt")];
}
