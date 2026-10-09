import type { SlashCommand } from "./slashCommands";

/** Commands owned by cmux and available in every harness chat. */
export type CmuxCommand = SlashCommand & { source: "cmux"; action: "import" | "continue" };

export const CMUX_COMMANDS: readonly CmuxCommand[] = [
  {
    name: "import",
    description: "",
    source: "cmux",
    action: "import",
  },
  {
    name: "continue",
    description: "",
    hint: "<harness>",
    source: "cmux",
    action: "continue",
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

export type HarnessTarget = { id: string; name: string };

/** Catalog entries that can receive a continuation from the currently shown harness. */
export function continueTargets<T extends HarnessTarget>(
  catalog: readonly (T & { pickable?: boolean; unavailable?: string })[],
  currentHarness: string | undefined,
): T[] {
  if (!currentHarness) return [];
  return catalog.filter((target) => target.id !== currentHarness && target.pickable !== false && !target.unavailable);
}

/** Resolves the target typed after `/continue` by id or its visible catalog name. */
export function resolveHarnessTarget(
  value: string | undefined,
  targets: readonly HarnessTarget[],
): HarnessTarget | undefined {
  const needle = value?.trim().toLocaleLowerCase();
  if (!needle) return undefined;
  return targets.find(
    (target) => target.id.toLocaleLowerCase() === needle || target.name.toLocaleLowerCase() === needle,
  );
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
