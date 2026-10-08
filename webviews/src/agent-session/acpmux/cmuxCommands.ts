import type { SlashCommand } from "./slashCommands";

/** Commands owned by cmux and available in every harness chat. */
export type CmuxCommand = SlashCommand & { source: "cmux"; action: "import" };

export const CMUX_COMMANDS: readonly CmuxCommand[] = [
  {
    name: "import",
    description: "",
    source: "cmux",
    action: "import",
  },
];

/** cmux commands come first, while a harness keeps the order it advertised. */
export function mergedCommands(agent: readonly SlashCommand[] | undefined): SlashCommand[] {
  const seen = new Set<string>();
  return [...CMUX_COMMANDS, ...(agent ?? [])].filter((command) => {
    const name = command.name.trim().toLowerCase();
    if (!name || seen.has(name)) return false;
    seen.add(name);
    return true;
  });
}

export function commandArgs(text: string, command: SlashCommand): string | undefined {
  const match = new RegExp(`^\\/${escapeRegExp(command.name)}(?:\\s+(.*))?$`, "is").exec(text.trim());
  return match ? (match[1]?.trim() ?? "") : undefined;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
