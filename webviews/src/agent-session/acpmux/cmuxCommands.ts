import { cliOnlyCommand } from "./cliOnlyCommands";
import type { StringKey } from "./i18n";
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
    | "btw"
    | "side"
    | "status";
  descriptionKey?: SlashCommand["descriptionKey"];
};

/// A handler's answer that the prompt goes to the harness as typed, through the normal send path
/// (attachments and steer included), as if cmux did not own the command.
export const CMUX_PASS_THROUGH: unique symbol = Symbol("cmux.passThrough");

const HARNESS_TOO: ReadonlySet<CmuxCommand["action"]> = new Set(["model", "fast", "context", "plan", "passThrough"]);

/// A command the harness also takes as typed: with no host to run cmux's own version, it is sent.
export function harnessTakesToo(command: CmuxCommand): boolean {
  return HARNESS_TOO.has(command.action);
}

/** A command handler may return a user-facing refusal while keeping the draft in the field. */
export type CmuxCommandResult = boolean | void | string | typeof CMUX_PASS_THROUGH | Promise<unknown>;

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
    description: "",
    descriptionKey: "composer.slashContext",
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
  {
    name: "side",
    description: "",
    descriptionKey: "composer.slashSide",
    source: "cmux",
    action: "side",
  },
  {
    name: "status",
    description: "",
    descriptionKey: "composer.slashStatus",
    source: "cmux",
    action: "status",
  },
];

/// Harnesses commonly expose these, but not every adapter advertises them through ACP. Keep a
/// cmux-owned fallback in the menu; an advertised entry wins and keeps the harness's description
/// and hint. The action sends the exact slash prompt through ACP.
const PASS_THROUGH_FALLBACKS: readonly CmuxCommand[] = [
  {
    name: "compact",
    description: "",
    descriptionKey: "composer.slashCompact",
    source: "cmux",
    action: "passThrough",
  },
  {
    name: "clear",
    description: "",
    descriptionKey: "composer.slashClear",
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
  const merged = [
    ...CMUX_COMMANDS.filter((command) => enabledCmuxActions.has(command.action)),
    ...(agent ?? []),
  ].filter((command) => {
    const name = command.name.trim().toLowerCase();
    if (!name || seen.has(name)) return false;
    seen.add(name);
    return true;
  });
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

/** Recognition is independent of menu availability: a disabled cmux command still belongs to cmux. */
export function composerCommand(
  text: string,
  harness?: string,
  attachmentCount = 0,
):
  | { kind: "cmux"; command: CmuxCommand; args: string }
  | { kind: "cliOnly"; key: StringKey; name: string }
  | undefined {
  const cliOnly = attachmentCount === 0 ? cliOnlyCommand(text, harness) : undefined;
  if (cliOnly) return { kind: "cliOnly", key: `composer.cliOnly.${cliOnly.use}`, name: cliOnly.name };
  for (const command of CMUX_COMMANDS) {
    const args = commandArgs(text, command);
    if (args !== undefined) return { kind: "cmux", command, args };
  }
}

/** The same refusal policy is used before either composer dispatches a command. */
export function cmuxCommandRefusal(
  command: CmuxCommand,
  args: string | undefined,
  state: {
    summary: boolean;
    forkable: boolean;
    sideAvailable: boolean;
    canContinue: boolean;
    sideSessions: boolean;
    session: boolean;
    isSideSession: boolean;
    targets: readonly HarnessTarget[];
  },
): StringKey | undefined {
  switch (command.action) {
    case "import":
    case "model":
    case "fast":
    case "context":
    case "plan":
    case "passThrough":
      return undefined;
    case "status":
      return state.summary ? undefined : "composer.cmuxStatusUnavailable";
    case "side":
      return !args?.trim() && state.forkable && state.sideAvailable ? undefined : "composer.cmuxSideUnavailable";
    case "fork":
      if (args?.trim()) return "composer.cmuxForkArgs";
      return state.forkable ? undefined : "composer.cmuxForkBusy";
    case "continue":
      if (args?.trim() && !resolveHarnessTarget(args, state.targets)) return "composer.cmuxContinueUnknown";
      return state.canContinue ? undefined : "composer.cmuxContinueBusy";
    case "btw":
      if (!state.sideSessions) return "composer.cmuxBtwDisabled";
      if (!args?.trim()) return "composer.cmuxBtwQuestion";
      return state.session && !state.isSideSession ? undefined : "composer.cmuxUnavailable";
  }
}
