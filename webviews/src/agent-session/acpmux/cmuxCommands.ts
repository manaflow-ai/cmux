import type { SlashCommand } from "./slashCommands";

/** Commands owned by cmux and available in every harness chat. Their description is a pane string. */
export type CmuxCommand = SlashCommand & {
  source: "cmux";
  action:
    | "model"
    | "fast"
    | "context"
    | "plan"
    | "passThrough"
    | "import"
    | "continue"
    | "fork"
    | "btw";
  descriptionKey?: SlashCommand["descriptionKey"];
};

export const CMUX_COMMANDS: readonly CmuxCommand[] = [
  {
    name: "model",
    description: "",
    descriptionKey: "picker.model",
    source: "cmux",
    action: "model",
  },
  {
    name: "fast",
    description: "",
    descriptionKey: "picker.fastMode",
    source: "cmux",
    action: "fast",
  },
  {
    name: "context",
    description: "Open context details",
    source: "cmux",
    action: "context",
  },
  {
    name: "plan",
    description: "",
    descriptionKey: "picker.plan",
    source: "cmux",
    action: "plan",
  },
  {
    name: "import",
    description: "",
    descriptionKey: "composer.slashImport",
    source: "cmux",
    action: "import",
  },
  {
    name: "continue",
    description: "",
    descriptionKey: "composer.slashContinue",
    hint: "<harness>",
    source: "cmux",
    action: "continue",
  },
  {
    name: "fork",
    description: "",
    descriptionKey: "composer.slashFork",
    source: "cmux",
    action: "fork",
  },
  {
    name: "btw",
    description: "",
    descriptionKey: "composer.slashBtw",
    hint: "<question>",
    source: "cmux",
    action: "btw",
  },
];

/// Harnesses commonly expose these, but not every adapter advertises them through ACP. Keep a
/// cmux-owned fallback in the menu; an advertised entry wins and keeps the harness's description
/// and hint. The action sends the exact slash prompt through ACP.
const PASS_THROUGH_FALLBACKS: readonly CmuxCommand[] = [
  {
    name: "compact",
    description: "Compact the conversation",
    source: "cmux",
    action: "passThrough",
  },
  {
    name: "clear",
    description: "Clear the conversation",
    source: "cmux",
    action: "passThrough",
  },
];

/** cmux commands come first, while a harness keeps the order it advertised. */
export function mergedCommands(
  agent: readonly SlashCommand[] | undefined,
  enabledCmuxActions: ReadonlySet<CmuxCommand["action"]> = new Set(CMUX_COMMANDS.map((command) => command.action)),
): SlashCommand[] {
  const seen = new Set<string>();
  const merged = [...CMUX_COMMANDS.filter((command) => enabledCmuxActions.has(command.action)), ...(agent ?? [])].filter(
    (command) => {
      const name = command.name.trim().toLowerCase();
      if (!name || seen.has(name)) return false;
      seen.add(name);
      return true;
    },
  );
  for (const fallback of PASS_THROUGH_FALLBACKS) {
    if (!seen.has(fallback.name)) {
      seen.add(fallback.name);
      merged.push(fallback);
    }
  }
  return merged;
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
