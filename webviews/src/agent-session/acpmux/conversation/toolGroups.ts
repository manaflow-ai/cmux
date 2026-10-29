// A run of tool calls split into what the transcript draws: consecutive calls of one kind
// under one line ("Ran 3 commands", "Read 4 files", "Edited App.tsx +12 -3"), messages to
// other agents (an `acpmux send` among them) and calls to the cmux-subsessions tools as cards,
// and everything else as its own row.
import { pathKey, type AcpmuxActivity } from "../model";
import type { Translate } from "../i18n";
import { isBareShellName } from "../toolPaths";
import { acpmuxSendCall, recordedMessageBodyChangesForTool, type AcpmuxSendCall } from "./acpmuxSends";
import { agentMessage, type AgentMessage } from "./agentMessages";
import { dispatchCall, type DispatchCall } from "./dispatchCalls";
import { mcpCall, mcpIsObservational, mcpKey } from "./mcpCalls";
import { subsessionCall, type SubsessionCall } from "./subsessionCalls";
import { isThought, mergeThoughts } from "./thoughts";

/// The kinds of call that group with their neighbors.
export type ToolGroupKind = "commands" | "reads" | "edits" | "searches";

export type ToolGroup =
  /// Its calls, with any thought that came between two of them in its place (`groupCalls` lists
  /// only the calls).
  | { type: "group"; kind: ToolGroupKind; items: AcpmuxActivity[] }
  | { type: "message"; item: AcpmuxActivity; message: AgentMessage }
  /// A first-class dispatch/steer/report operation, kept visible beside folded tool work.
  | { type: "dispatch"; item: AcpmuxActivity; call: DispatchCall }
  /// A shell `acpmux send` (acpmuxSends.ts): the sent-message row (SentMessageLine.tsx).
  | { type: "send"; item: AcpmuxActivity; send: AcpmuxSendCall }
  /// A sub-session started, sent a message or waited on (subsessionCalls.ts), each its own card.
  | { type: "subsession"; item: AcpmuxActivity; call: SubsessionCall }
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

/// Consecutive calls of one kind form a group; a call of another kind ends it. A thought between
/// two commands, reads or searches stays inside their group, in its place, so thinking between
/// calls never splits one run of reads into many small groups (Leo 2026-10-21: "it can consolidate
/// a ton of these tool calls"); a thought before any other entry ends the group. Commands, reads
/// and searches group from two calls; an edit with a diff groups alone, so it still reads "Edited
/// App.tsx +12 -3". Calls to one MCP tool group from one call, so even a lone one reads as what it
/// did. A lone call of any other kind keeps its own row and title. Consecutive thoughts are one
/// thought (thoughts.ts `mergeThoughts`).
export function toolGroups(items: readonly AcpmuxActivity[]): ToolGroup[] {
  const groups: ToolGroup[] = [];
  // One turn's bounded, transcript-recorded message files. A later Bash `acpmux send - <file>`
  // may use a body written by an earlier Bash call; no host filesystem read is allowed here.
  const messageFiles = new Map<string, string>();
  const messageFileEndedAt = new Map<string, number | undefined>();
  // Earlier calls may finish after a later writer. Keep one completion horizon for all possible
  // aliases, and leave provenance unknown while any preceding mutation has no proven end.
  let mutationEndedAt = -Infinity;
  let mutationUnsettled = false;
  let run: { kind: ToolGroupKind; items: AcpmuxActivity[] } | undefined;
  let mcp: { key: string; items: AcpmuxActivity[] } | undefined;
  // Thoughts after the open run's latest call: they join it if a call of its kind comes next.
  let held: AcpmuxActivity[] = [];
  const close = () => {
    if (mcp) groups.push({ type: "mcp", items: mcp.items });
    mcp = undefined;
    if (run) {
      const lone = run.items[0]!.tool!;
      if (run.items.length >= 2 || (run.kind === "edits" && lone.diffs?.length)) groups.push({ type: "group", ...run });
      else groups.push({ type: "item", item: run.items[0]! });
      run = undefined;
    }
    for (const thought of held) groups.push({ type: "item", item: thought });
    held = [];
  };
  for (const item of mergeThoughts(items)) {
    if (run && run.kind !== "edits" && isThought(item)) {
      held.push(item);
      continue;
    }
    const tool = item.tool;
    const dispatch = tool ? dispatchCall(item) : undefined;
    let send = tool && !dispatch ? acpmuxSendCall(tool, messageFiles) : undefined;
    if (send && messageFiles.size) {
      const startsAt = tool?.startedAt;
      const ordered =
        startsAt !== undefined && [...messageFileEndedAt.values()].every((end) => end !== undefined && end <= startsAt);
      if (!ordered) {
        messageFiles.clear();
        messageFileEndedAt.clear();
        send = tool && !dispatch ? acpmuxSendCall(tool) : undefined;
      }
    }
    const message = tool && !dispatch && !send ? agentMessage(tool) : undefined;
    const named = tool && !dispatch && !send && !message ? mcpCall(tool) : undefined;
    const subsession = named && subsessionCall(tool!, named);
    const call = subsession ? undefined : named;
    const key = call && mcpKey(call);
    const rememberMessageFiles = () => {
      if (!tool) return;
      // A parsed MCP action must itself be observational: a generic ACP read/search/fetch kind
      // cannot make write_file or read_and_write safe. Explicit mutation kinds still invalidate.
      // Observational status or missing timestamps cannot replace a producer or block a later one.
      const parsedMcp = !tool.command && mcpCall(tool);
      const observationalKind = tool.kind === "read" || tool.kind === "search" || tool.kind === "fetch";
      const observational = parsedMcp
        ? mcpIsObservational(parsedMcp) && (!tool.kind || observationalKind)
        : observationalKind;
      if (!tool.command && !tool.diffs?.length && !tool.background && observational) return;
      const endedAt = tool.background ? tool.background.endedAt : tool.endedAt;
      const rememberMutation = () => {
        const ended = tool.background
          ? tool.background.state === "completed" ||
            tool.background.state === "failed" ||
            tool.background.state === "stopped"
          : tool.status === "completed" || tool.status === "failed";
        if (
          !ended ||
          endedAt === undefined ||
          !Number.isFinite(endedAt) ||
          (tool.startedAt !== undefined && (!Number.isFinite(tool.startedAt) || tool.startedAt > endedAt))
        )
          mutationUnsettled = true;
        else mutationEndedAt = Math.max(mutationEndedAt, endedAt);
      };
      // A failed or still-running writer did not produce a durable body. Clear the bounded
      // producer set so a later send cannot display stale content from an earlier call.
      if (
        !tool.command ||
        tool.status !== "completed" ||
        (tool.exitCode !== undefined && tool.exitCode !== 0) ||
        (tool.background && tool.background.state !== "completed")
      ) {
        rememberMutation();
        messageFiles.clear();
        messageFileEndedAt.clear();
        return;
      }
      // A background call's foreground row can finish before the actual shell. Use the
      // background completion timestamp for provenance; without it, ordering against a later
      // send is unknown and the body must remain unresolved.
      if (endedAt === undefined || !Number.isFinite(endedAt)) {
        rememberMutation();
        messageFiles.clear();
        messageFileEndedAt.clear();
        return;
      }
      const changes = recordedMessageBodyChangesForTool(tool);
      const startedAt = tool.startedAt;
      const orderedWriter =
        !mutationUnsettled &&
        startedAt !== undefined &&
        Number.isFinite(startedAt) &&
        startedAt >= mutationEndedAt &&
        startedAt <= endedAt;
      if (changes.length) rememberMutation();
      for (const change of changes) {
        if ("reset" in change) {
          messageFiles.clear();
          messageFileEndedAt.clear();
          continue;
        }
        if (change.text === undefined) {
          messageFiles.delete(change.path);
          messageFileEndedAt.delete(change.path);
        } else {
          // A newly accepted producer supersedes every previous path spelling. We cannot resolve
          // aliases without filesystem access, so clear all candidates before recording it.
          messageFiles.clear();
          messageFileEndedAt.clear();
          if (!orderedWriter) continue;
          messageFiles.set(change.path, change.text);
          messageFileEndedAt.set(change.path, endedAt);
          while (messageFiles.size > 64) messageFiles.delete(messageFiles.keys().next().value!);
        }
      }
    };
    if (key && mcp?.key === key) {
      mcp.items.push(item);
      rememberMessageFiles();
      continue;
    }
    const kind = tool && !send && !message && !subsession && !call ? toolGroupKind(tool) : undefined;
    if (kind && run?.kind === kind) {
      run.items.push(...held, item);
      held = [];
      rememberMessageFiles();
      continue;
    }
    close();
    if (dispatch) groups.push({ type: "dispatch", item, call: dispatch });
    else if (send) groups.push({ type: "send", item, send });
    else if (message) groups.push({ type: "message", item, message });
    else if (subsession) groups.push({ type: "subsession", item, call: subsession });
    else if (key) mcp = { key, items: [item] };
    else if (kind) run = { kind, items: [item] };
    else groups.push({ type: "item", item });
    rememberMessageFiles();
  }
  close();
  return groups;
}

/// A group's calls, without the thoughts between them.
export function groupCalls(items: readonly AcpmuxActivity[]): AcpmuxActivity[] {
  return items.filter((item) => item.tool);
}

/// A file change (an edit, a delete, a move) still waiting for its permission: its row stays in
/// sight, never folded under a run's summary line, so the change it asks about can be seen.
export function awaitsPermission(tool: Tool | undefined): boolean {
  return (
    tool?.status === "pending" &&
    (tool.kind === "edit" || tool.kind === "delete" || tool.kind === "move" || tool.kind === "fileChange")
  );
}

export function isRunning(tool: Tool): boolean {
  return tool.status === "pending" || tool.status === "in_progress";
}

/// A shell call in flight with nothing to show yet: Claude sends a call before its input, which
/// the model is still writing (a Bash with no command for up to 20s), and one a turn left that way
/// never gets any. Its row would only say "Running a command", so the transcript draws none
/// (conversation/turns.ts `withoutDrafts`): the live line names it ("Writing a command"), and its
/// row comes with its input. Only a shell call: another tool may take no input at all (`{}`), and
/// its row is the only record that it ran.
export function isDraftCall(tool: Tool): boolean {
  return (
    isRunning(tool) &&
    tool.kind === "execute" &&
    isBareShellName(tool, tool.title) &&
    !tool.description &&
    !tool.output &&
    !tool.background &&
    !tool.diffs?.length &&
    !tool.locations?.length &&
    !tool.images?.length &&
    !/[^\s{}[\]]/.test(tool.inputSummary ?? "")
  );
}

/// A call that failed: its status says so or its command exited nonzero.
export function isFailed(tool: Tool): boolean {
  return tool.status === "failed" || (tool.exitCode !== undefined && tool.exitCode !== 0);
}

/// The distinct files a run of reads opened, by their locations (model.ts `pathKey`), or one per
/// call without any.
function readCount(items: readonly AcpmuxActivity[]): number {
  const paths = new Set<string>();
  let unnamed = 0;
  for (const item of items) {
    const locations = item.tool?.locations ?? [];
    if (!locations.length) unnamed++;
    for (const location of locations) paths.add(pathKey(location));
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
  const calls = groupCalls(items);
  const running = calls.some((item) => isRunning(item.tool!));
  switch (kind) {
    case "commands":
      return t(running ? "tools.running" : "tools.ran", { n: calls.length });
    case "reads": {
      const n = readCount(calls);
      return t(n === 1 ? "tools.read.one" : "tools.read.other", { n });
    }
    case "searches":
      return t("tools.searched", { n: calls.length });
    case "edits": {
      // Calls without a diff (a delete or move the agent did not diff) count as a file each.
      const n = files.length + calls.filter((item) => !item.tool?.diffs?.length).length;
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
