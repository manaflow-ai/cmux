// A run of tool calls split into what the transcript draws: consecutive calls of one kind
// under one line ("Ran 3 commands", "Read 4 files", "Edited App.tsx +12 -3"), messages to
// other agents (an `acpmux send` among them) and calls to the cmux-subsessions tools as cards,
// and everything else as its own row.
import { pathKey, type AcpmuxActivity, type AcpmuxRow } from "../model";
import type { Translate } from "../i18n";
import { isBareShellName } from "../toolPaths";
import { acpmuxMcpSends } from "./acpmuxMcpSends";
import { acpmuxSendCalls, recordedMessageBodyChangesForTool, type AcpmuxSendCallPart } from "./acpmuxSends";
import { agentMessage, type AgentMessage } from "./agentMessages";
import { dispatchCall, type DispatchCall } from "./dispatchCalls";
import { isCmuxExec } from "./cmuxExec";
import { mcpCall, mcpIsObservational, mcpKey } from "./mcpCalls";
import { subsessionCall, type SubsessionCall } from "./subsessionCalls";
import { isThought, mergeThoughts } from "./thoughts";
import { isFoldedRun } from "./toolRunSummary";

/// The kinds of call that group with their neighbors.
export type ToolGroupKind = "commands" | "reads" | "edits" | "searches";

export type ToolGroup =
  /// Its calls, with any thought that came between two of them in its place (`groupCalls` lists
  /// only the calls).
  | { type: "group"; kind: ToolGroupKind; items: AcpmuxActivity[] }
  | { type: "message"; item: AcpmuxActivity; message: AgentMessage }
  /// A first-class dispatch/steer/report operation, kept visible beside folded tool work.
  | { type: "dispatch"; item: AcpmuxActivity; call: DispatchCall }
  /// A message a shell `acpmux send` (acpmuxSends.ts) or the acpmux MCP send's batch, file or tag
  /// shape (acpmuxMcpSends.ts) sent: the sent-message row (SentMessageLine.tsx). A call that sent
  /// several (a batch) is one entry per message, all with the same `item`.
  | { type: "send"; item: AcpmuxActivity; send: AcpmuxSendCallPart }
  /// A sub-session started, sent a message or waited on (subsessionCalls.ts), each its own card.
  | { type: "subsession"; item: AcpmuxActivity; call: SubsessionCall }
  /// Adjacent start_session calls become one disclosure row with one expandable child per session.
  | {
      type: "subsessionGroup";
      items: AcpmuxActivity[];
      calls: Extract<SubsessionCall, { tool: "start" }>[];
    }
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
/// a ton of these tool calls"). The thoughts that lead into a run of commands, reads or searches
/// open its group, as Claude Code desktop draws a run's thinking first inside it; they keep their
/// own rows when the run stays one call. A thought before any other entry ends the group. Commands, reads
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
  let run: { kind: ToolGroupKind; items: AcpmuxActivity[]; lead: number } | undefined;
  let mcp: { key: string; items: AcpmuxActivity[] } | undefined;
  let subsessionGroup:
    | {
        items: AcpmuxActivity[];
        calls: Extract<SubsessionCall, { tool: "start" }>[];
      }
    | undefined;
  // Thoughts after the open run's latest call: they join it if a call of its kind comes next.
  let held: AcpmuxActivity[] = [];
  // Thoughts no run holds yet: they lead the next run of commands, reads or searches, or draw on
  // their own before whatever else comes.
  let lead: AcpmuxActivity[] = [];
  const flushLead = () => {
    for (const thought of lead) groups.push({ type: "item", item: thought });
    lead = [];
  };
  /// `keep`: the open run's trailing thoughts wait to lead whatever comes next.
  const close = (keep = false) => {
    if (subsessionGroup) {
      if (subsessionGroup.calls.length === 1)
        groups.push({ type: "subsession", item: subsessionGroup.items[0]!, call: subsessionGroup.calls[0]! });
      else groups.push({ type: "subsessionGroup", ...subsessionGroup });
      subsessionGroup = undefined;
    }
    if (mcp) groups.push({ type: "mcp", items: mcp.items });
    mcp = undefined;
    if (run) {
      const lone = run.items[run.lead]!.tool!;
      if (run.items.length - run.lead >= 2 || (run.kind === "edits" && lone.diffs?.length))
        groups.push({ type: "group", kind: run.kind, items: run.items });
      else for (const item of run.items) groups.push({ type: "item", item });
      run = undefined;
    }
    if (keep) lead.push(...held);
    else for (const thought of held) groups.push({ type: "item", item: thought });
    held = [];
  };
  for (const item of mergeThoughts(items)) {
    // A thought inside an open run of commands, reads or searches waits in `held` for the run's
    // next call; any other thought (none open, or an edits run) closes what is open and waits in
    // `lead` to open the next run.
    if (isThought(item)) {
      if (run && run.kind !== "edits") held.push(item);
      else {
        close(true);
        lead.push(item);
      }
      continue;
    }
    const tool = item.tool;
    const dispatch = tool ? dispatchCall(item) : undefined;
    let send = tool && !dispatch ? acpmuxSendCalls(tool, messageFiles) : undefined;
    if (send && messageFiles.size) {
      const startsAt = tool?.startedAt;
      const ordered =
        startsAt !== undefined && [...messageFileEndedAt.values()].every((end) => end !== undefined && end <= startsAt);
      if (!ordered) {
        messageFiles.clear();
        messageFileEndedAt.clear();
        send = tool && !dispatch ? acpmuxSendCalls(tool) : undefined;
      }
    }
    if (!send && tool && !dispatch) send = acpmuxMcpSends(tool);
    const message = tool && !dispatch && !send ? agentMessage(tool) : undefined;
    const named = tool && !dispatch && !send && !message ? mcpCall(tool) : undefined;
    const subsession = named && subsessionCall(tool!, named);
    const call = subsession ? undefined : named;
    // A cmux script is its own row even beside another: each says what it did (cmuxExec.ts).
    const key = call && (isCmuxExec(call) ? `${mcpKey(call)}\u0000${tool!.id}` : mcpKey(call));
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
    if (subsession?.tool === "start") {
      if (subsessionGroup) {
        subsessionGroup.items.push(item);
        subsessionGroup.calls.push(subsession);
      } else {
        close();
        flushLead();
        subsessionGroup = { items: [item], calls: [subsession] };
      }
      rememberMessageFiles();
      continue;
    }
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
    close(true);
    if (kind && kind !== "edits") {
      run = { kind, items: [...lead, item], lead: lead.length };
      lead = [];
      rememberMessageFiles();
      continue;
    }
    flushLead();
    if (dispatch) groups.push({ type: "dispatch", item, call: dispatch });
    else if (send) for (const part of send) groups.push({ type: "send", item, send: part });
    else if (message) groups.push({ type: "message", item, message });
    else if (subsession) groups.push({ type: "subsession", item, call: subsession });
    else if (key) mcp = { key, items: [item] };
    else if (kind) run = { kind, items: [item], lead: 0 };
    else groups.push({ type: "item", item });
    rememberMessageFiles();
  }
  close();
  flushLead();
  return groups;
}

/// The id a group is known by: its first call's, since thoughts that led into the run may come
/// before it (the same id the group had before a thought joined it).
export function groupId(items: readonly AcpmuxActivity[]): string | undefined {
  return items.find((item) => item.tool)?.tool?.id;
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

/// A folded run's entries in stretches: a coordination card (a message, a sub-session started,
/// messaged or waited on) stays in sight, its own stretch, and the work between cards folds under
/// its own summary line ("Edited a file, read 6 files, ran 4 commands") once it holds two calls in
/// more than one entry, so one card never leaves the whole run spread out as a list
/// (Leo 2026-10-21: "it can consolidate a ton of these tool calls"). A run that is not folded
/// (`foldRun`, the Codex-style runs) is one stretch that folds nothing.
export type RunStretch = { from: number; groups: ToolGroup[]; items: AcpmuxActivity[]; fold: boolean };

export function runStretches(row: AcpmuxRow, groups: readonly ToolGroup[]): RunStretch[] {
  const stretches: RunStretch[] = [];
  let current: RunStretch | undefined;
  const close = () => {
    if (current) current.fold = current.groups.length > 1 && isFoldedRun(current.items);
    current = undefined;
  };
  groups.forEach((group, at) => {
    const items = "items" in group ? group.items : [group.item];
    if (row.foldRun === true && staysInSight(group)) {
      close();
      stretches.push({ from: at, groups: [group], items, fold: false });
      return;
    }
    if (!current) stretches.push((current = { from: at, groups: [], items: [], fold: false }));
    current.groups.push(group);
    current.items.push(...items);
  });
  close();
  if (row.foldRun !== true) for (const stretch of stretches) stretch.fold = false;
  return stretches;
}

/// An entry a folded run keeps in sight beside its summary lines: a coordination card, or a file
/// change still waiting for its permission (toolGroups.ts `awaitsPermission`). Other edits fold with
/// the rest of the work and the line names them (Leo 2026-10-22: "this is pretty good ui: … the
/// collapsing i mean"); the turn's edited-files card lists them once it ends.
export function staysInSight(group: ToolGroup): boolean {
  if (
    group.type === "message" ||
    group.type === "send" ||
    group.type === "subsession" ||
    group.type === "subsessionGroup" ||
    group.type === "dispatch"
  )
    return true;
  // A pending change draws as its own item (toolGroups.ts `toolGroupKind`); any entry holding one
  // stays in sight all the same.
  return ("items" in group ? group.items : [group.item]).some((item) => awaitsPermission(item.tool));
}
