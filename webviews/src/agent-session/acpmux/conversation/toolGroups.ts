// A run of tool calls split into what the transcript draws: consecutive calls of one kind
// under one line ("Ran 3 commands", "Read 4 files", "Edited App.tsx +12 -3"), messages to
// other agents as cards, and everything else as its own row.
import type { AcpmuxActivity } from "../model";
import { t } from "../i18n";
import { agentMessage, type AgentMessage } from "./agentMessages";

/// The kinds of call that group with their neighbors.
export type ToolGroupKind = "commands" | "reads" | "edits" | "searches";

export type ToolGroup =
  | { type: "group"; kind: ToolGroupKind; items: AcpmuxActivity[] }
  | { type: "message"; item: AcpmuxActivity; message: AgentMessage }
  | { type: "item"; item: AcpmuxActivity };

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The group a call joins, or nil for a call drawn on its own. Only calls with a command line
/// are commands; an MCP call can also say "execute".
export function toolGroupKind(tool: Tool): ToolGroupKind | undefined {
  switch (tool.kind) {
    case "execute":
      return tool.command ? "commands" : undefined;
    case "read":
      return "reads";
    case "edit":
    case "delete":
    case "move":
    case "fileChange":
      return "edits";
    case "search":
      return "searches";
    default:
      return undefined;
  }
}

/// Consecutive calls of one kind form a group; a thought or a call of another kind ends it.
/// Commands, reads and searches group from two calls; an edit with a diff groups alone, so it
/// still reads "Edited App.tsx +12 -3". A lone call of any other kind keeps its own row and title.
export function toolGroups(items: readonly AcpmuxActivity[]): ToolGroup[] {
  const groups: ToolGroup[] = [];
  let run: { kind: ToolGroupKind; items: AcpmuxActivity[] } | undefined;
  const close = () => {
    if (!run) return;
    const lone = run.items[0]!.tool!;
    if (run.items.length >= 2 || (run.kind === "edits" && lone.diffs?.length)) groups.push({ type: "group", ...run });
    else groups.push({ type: "item", item: run.items[0]! });
    run = undefined;
  };
  for (const item of items) {
    const tool = item.tool;
    const message = tool && agentMessage(tool);
    const kind = tool && !message ? toolGroupKind(tool) : undefined;
    if (kind && run?.kind === kind) {
      run.items.push(item);
      continue;
    }
    close();
    if (message) groups.push({ type: "message", item, message });
    else if (kind) run = { kind, items: [item] };
    else groups.push({ type: "item", item });
  }
  close();
  return groups;
}

export function isRunning(tool: Tool): boolean {
  return tool.status === "pending" || tool.status === "in_progress";
}

/// A call that failed: its status says so or its command exited nonzero.
export function isFailed(tool: Tool): boolean {
  return tool.status === "failed" || (tool.exitCode !== undefined && tool.exitCode !== 0);
}

/// The distinct files a run of reads opened, by their locations, or one per call without any.
function readCount(items: readonly AcpmuxActivity[]): number {
  const paths = new Set<string>();
  let unnamed = 0;
  for (const item of items) {
    const locations = item.tool?.locations ?? [];
    if (!locations.length) unnamed++;
    for (const location of locations) paths.add(location.path);
  }
  return paths.size + unnamed;
}

/// The group's line, without the edit counts its row draws in the diff colors. `files` are the
/// paths an edit group changed: one names its file, more count them.
export function toolGroupLabel(
  kind: ToolGroupKind,
  items: readonly AcpmuxActivity[],
  files: readonly string[] = [],
): string {
  const running = items.some((item) => item.tool && isRunning(item.tool));
  switch (kind) {
    case "commands":
      return t(running ? "tools.running" : "tools.ran", { n: items.length });
    case "reads": {
      const n = readCount(items);
      return t(n === 1 ? "tools.read.one" : "tools.read.other", { n });
    }
    case "searches":
      return t("tools.searched", { n: items.length });
    case "edits": {
      // Calls without a diff (a delete or move the agent did not diff) count as a file each.
      const n = files.length + items.filter((item) => !item.tool?.diffs?.length).length;
      return n === 1 && files.length === 1
        ? t("tools.edited.file", { file: fileName(files[0]!) })
        : t("tools.edited.files", { n });
    }
  }
}

/// A finished call's run time, from its first event to the one that ended it: "840ms", "4.2s", "2m 5s".
export function toolDuration(tool: Tool): string | undefined {
  if (tool.startedAt === undefined || tool.endedAt === undefined) return undefined;
  const ms = Math.max(0, tool.endedAt - tool.startedAt);
  if (ms < 1000) return t("duration.ms", { n: ms });
  if (ms < 60_000) return t("duration.s", { n: (ms / 1000).toFixed(1) });
  const seconds = Math.round(ms / 1000);
  return t("duration.m", { m: Math.floor(seconds / 60), s: seconds % 60 });
}

/// The last path component, for "Edited App.tsx".
export function fileName(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}
