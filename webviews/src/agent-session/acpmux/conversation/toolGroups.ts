// A run of tool calls split into what the transcript draws: consecutive calls of one kind
// under one line ("Ran 3 commands", "Read 4 files", "Edited App.tsx +12 -3"), messages to
// other agents as cards, and everything else as its own row.
import type { AcpmuxActivity } from "../model";
import type { Translate } from "../i18n";
import { agentMessage, type AgentMessage } from "./agentMessages";
import { mcpCall, mcpKey } from "./mcpCalls";
import { mergeThoughts } from "./thoughts";

/// The kinds of call that group with their neighbors.
export type ToolGroupKind = "commands" | "reads" | "edits" | "searches";

export type ToolGroup =
  | { type: "group"; kind: ToolGroupKind; items: AcpmuxActivity[] }
  | { type: "message"; item: AcpmuxActivity; message: AgentMessage }
  /// Consecutive calls to one MCP server's tool (mcpCalls.ts), one or more.
  | { type: "mcp"; items: AcpmuxActivity[] }
  | { type: "item"; item: AcpmuxActivity };

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// The group a call joins, or nil for a call drawn on its own. Only calls with a command line
/// are commands; an MCP call can also say "execute". An edit still waiting for its permission
/// ("pending") is drawn as the call, not as "Edited" (cx-p5fgx).
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
      return tool.status === "pending" ? undefined : "edits";
    case "search":
      return "searches";
    default:
      return undefined;
  }
}

/// Consecutive calls of one kind form a group; a thought or a call of another kind ends it.
/// Commands, reads and searches group from two calls; an edit with a diff groups alone, so it
/// still reads "Edited App.tsx +12 -3". Calls to one MCP tool group from one call, so even a lone
/// one reads as what it did. A lone call of any other kind keeps its own row and title.
/// Consecutive thoughts are one thought (thoughts.ts `mergeThoughts`).
export function toolGroups(items: readonly AcpmuxActivity[]): ToolGroup[] {
  const groups: ToolGroup[] = [];
  let run: { kind: ToolGroupKind; items: AcpmuxActivity[] } | undefined;
  let mcp: { key: string; items: AcpmuxActivity[] } | undefined;
  const close = () => {
    if (mcp) groups.push({ type: "mcp", items: mcp.items });
    mcp = undefined;
    if (!run) return;
    const lone = run.items[0]!.tool!;
    if (run.items.length >= 2 || (run.kind === "edits" && lone.diffs?.length)) groups.push({ type: "group", ...run });
    else groups.push({ type: "item", item: run.items[0]! });
    run = undefined;
  };
  for (const item of mergeThoughts(items)) {
    const tool = item.tool;
    const message = tool && agentMessage(tool);
    const call = tool && !message ? mcpCall(tool) : undefined;
    const key = call && mcpKey(call);
    if (key && mcp?.key === key) {
      mcp.items.push(item);
      continue;
    }
    const kind = tool && !message && !call ? toolGroupKind(tool) : undefined;
    if (kind && run?.kind === kind) {
      run.items.push(item);
      continue;
    }
    close();
    if (message) groups.push({ type: "message", item, message });
    else if (key) mcp = { key, items: [item] };
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
  t: Translate,
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
/// A shell that went on in the background ran until it ended there, and has no time while it runs.
export function toolDuration(t: Translate, tool: Tool): string | undefined {
  const end = tool.background ? tool.background.endedAt : tool.endedAt;
  if (tool.startedAt === undefined || end === undefined) return undefined;
  const ms = Math.max(0, end - tool.startedAt);
  if (ms < 1000) return t("duration.ms", { n: ms });
  if (ms < 60_000) return t("duration.s", { n: (ms / 1000).toFixed(1) });
  const seconds = Math.round(ms / 1000);
  return t("duration.m", { m: Math.floor(seconds / 60), s: seconds % 60 });
}

/// The last path component, for "Edited App.tsx".
export function fileName(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}
