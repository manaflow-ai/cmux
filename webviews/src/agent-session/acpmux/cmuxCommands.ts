import { cliOnlyCommand } from "./cliOnlyCommands";
import type { ConnectorServer } from "./session-info/connectorServers";
import type { ChatTool } from "./summary/chatTools";
import type { StringKey } from "./i18n";
import { goesAsText, type SlashCommand } from "./slashCommands";

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
    | "status"
    | "cd"
    | "resume"
    | "login"
    | "mcp";
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

/// A command's own sentence for a refusal that comes after its async work (`/cd` to a path the
/// host says is no folder); the composer shows it in place of the generic one.
export class CmuxCommandRefused extends Error {}

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
  {
    name: "cd",
    description: "",
    descriptionKey: "composer.slashCd",
    hint: "<folder>",
    source: "cmux",
    action: "cd",
  },
  // Claude Code's own /resume and /login need its terminal UI; these are the GUI's (Lawrence:
  // "in gui, having /resume would be nice, maybe /login as well"). /resume opens the chats search.
  {
    name: "resume",
    description: "",
    descriptionKey: "composer.slashResume",
    source: "cmux",
    action: "resume",
  },
  {
    name: "login",
    description: "",
    descriptionKey: "composer.slashLogin",
    source: "cmux",
    action: "login",
  },
  // Claude Code's own /mcp is a terminal menu (over ACP it answers "isn't available in this
  // environment") and Codex's app-server takes no slash commands, so a typed /mcp did nothing useful
  // in a GUI chat (user, 2026-11-06: "/mcp doesn't work in cmux agent GUIs"). cmux's shows the chat's
  // MCP servers in Session Info's Connectors, and its subcommands do what that menu's rows do.
  {
    name: "mcp",
    description: "",
    descriptionKey: "composer.slashMcp",
    hint: "[<action> <server>]",
    source: "cmux",
    action: "mcp",
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

/** cmux commands come first, while a harness keeps the order it advertised. A command of the
 *  harness's own with a cmux name gives way to cmux's; a skill or prompt with one stays: mid-prompt
 *  it is the only meaning (slashCommands.ts goesAsText), and at the start cmux's still runs. */
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
    const key = `${goesAsText(command) ? "text" : "run"}:${name}`;
    if (!name || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  for (const fallback of PASS_THROUGH_FALLBACKS) {
    if (!seen.has(`run:${fallback.name}`)) {
      seen.add(`run:${fallback.name}`);
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

/** Catalog entries that can receive a continuation from the currently shown harness. The daemon
 *  refuses a target of the source's own family (`same_harness`, hub/handoff/ops.rs), so another
 *  profile of that family (a router profile of Claude, say) is no target either. */
export function continueTargets<T extends HarnessTarget>(
  catalog: readonly (T & { pickable?: boolean; unavailable?: string; family?: string })[],
  currentHarness: string | undefined,
  sourceFamily?: string,
): T[] {
  if (!currentHarness) return [];
  const familyOf = (entry: { id: string; family?: string }) => entry.family ?? entry.id;
  // A running session keeps its family when its catalog profile is reloaded. Match the
  // daemon's persisted-family fallback, rather than inferring from the mutable catalog.
  const currentFamily = sourceFamily ?? currentHarness;
  return catalog.filter(
    (target) =>
      target.id !== currentHarness &&
      familyOf(target) !== currentFamily &&
      target.pickable !== false &&
      !target.unavailable,
  );
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
    /// The chat's folder, which `/cd` reads a relative path against (undefined: none reported).
    cwd?: string;
    /// New Tab, whose own project chip picks its folder.
    newTab?: boolean;
  },
): StringKey | undefined {
  switch (command.action) {
    case "import":
    case "model":
    case "fast":
    case "context":
    case "plan":
    case "passThrough":
    case "resume":
    case "login":
      return undefined;
    case "mcp":
      return state.newTab || !state.session ? "composer.cmuxMcpUnavailable" : undefined;
    case "status":
      return state.summary ? undefined : "composer.cmuxStatusUnavailable";
    case "cd":
      if (state.newTab) return "composer.cmuxCdNewTab";
      return !args?.trim() || cdFolder(args, state.cwd) ? undefined : "composer.cmuxCdPath";
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

/// The folder `/cd <folder>` names: an absolute path as typed, or one relative to the chat's folder
/// (`..`, `./src`, `src`), with `.` and `..` resolved and no trailing slash. Undefined when it
/// cannot be read here: `~` (the host's home is not the pane's to spell) or a relative path with
/// no chat folder to read it against.
export function cdFolder(args: string | undefined, cwd: string | undefined): string | undefined {
  let typed = args?.trim() ?? "";
  // A path pasted in quotes, as a shell would take it.
  if (typed.length >= 2 && (typed[0] === '"' || typed[0] === "'") && typed.at(-1) === typed[0])
    typed = typed.slice(1, -1).trim();
  if (!typed || typed.startsWith("~")) return undefined;
  const base = typed.startsWith("/") ? "" : cwd;
  if (base === undefined || (base && !base.startsWith("/"))) return undefined;
  const parts: string[] = [];
  for (const part of `${base}/${typed}`.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return `/${parts.join("/")}`;
}

/// What `/mcp <args>` does in a chat: show the chat's MCP servers (bare), reconnect one, or turn
/// one on or off for this chat, as Session Info's Connectors and Use tools do. A refusal names why.
export type McpCommandPlan =
  | { kind: "show" }
  | { kind: "reconnect"; server: string }
  | { kind: "set"; id: string; server: string; enabled: boolean }
  | { kind: "refuse"; key: StringKey; values?: Record<string, string> };

export function mcpCommandPlan(
  args: string | undefined,
  chat: {
    /// The chat's servers as Connectors lists them (connectorServers.ts).
    servers: readonly ConnectorServer[];
    /// acpmux's `tools` for the chat, whose `mcp:<server>` rows say which can turn on or off.
    tools?: readonly ChatTool[];
    /// acpmux reconnects this chat's servers (`_acpmux/mcp/reconnect`: a Claude Code chat).
    reconnects: boolean;
    /// Why `_acpmux/set_tools` cannot change this chat's tools from this page; unset: it can.
    toolsRefusal?: StringKey;
  },
): McpCommandPlan {
  const typed = args?.trim() ?? "";
  if (!typed) return { kind: "show" };
  const match = /^(\S+)(?:\s+(.+))?$/s.exec(typed);
  const verb = match?.[1]?.toLowerCase();
  const name = match?.[2]?.trim();
  if (!name || (verb !== "reconnect" && verb !== "enable" && verb !== "disable"))
    return { kind: "refuse", key: "composer.cmuxMcpUsage" };
  // The server as the chat names it: exact first, then ignoring case.
  const names = [
    ...chat.servers.map((server) => server.name),
    ...(chat.tools ?? []).filter((tool) => tool.id.startsWith("mcp:")).map((tool) => tool.id.slice(4)),
  ];
  const server =
    names.find((known) => known === name) ?? names.find((known) => known.toLowerCase() === name.toLowerCase());
  if (!server) return { kind: "refuse", key: "composer.cmuxMcpUnknown", values: { server: name } };
  if (verb === "reconnect") {
    if (!chat.reconnects) return { kind: "refuse", key: "composer.cmuxMcpNoReconnect" };
    return { kind: "reconnect", server };
  }
  const tool = chat.tools?.find((row) => row.id === `mcp:${server}`);
  if (chat.toolsRefusal) return { kind: "refuse", key: chat.toolsRefusal };
  if (!tool?.canToggle) return { kind: "refuse", key: "summary.tools.fixed" };
  return { kind: "set", id: tool.id, server, enabled: verb === "enable" };
}
