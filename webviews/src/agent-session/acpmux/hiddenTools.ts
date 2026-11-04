// Tool calls the transcript treats as discovery plumbing: they only load deferred schemas and do
// nothing the person asked for. A successful discovery row is hidden and excluded from the
// "Worked for" summary; pending and failed calls remain visible so their state can be acted on.

/// Discovery tools that only load deferred schemas, by their adapter name.
const PLUMBING_TOOLS: ReadonlySet<string> = new Set(["ToolSearch", "tool_search", "load_tools"]);

/// Whether an ACP `tool_call` is discovery plumbing the transcript hides when it completes. Only a
/// call named as Claude Code's own tool counts (acpmux's `_meta.claude.tool`, the ACP adapter's
/// `_meta.claudeCode.toolName`):
/// a title alone could be any other agent's or MCP server's tool.
export function isPlumbingCall(update: any): boolean {
  const tool = update?._meta?.claude?.tool ?? update?._meta?.claudeCode?.toolName;
  return typeof tool === "string" && PLUMBING_TOOLS.has(tool);
}

/// A completed plumbing call stays in the source row for Find/copy/export, but does not count as
/// work in the turn summary. Presentation filters the same call from the visible step list.
export function isCompletedPlumbingTool(tool: any): boolean {
  const name = tool?.provenance?.claudeTool ?? tool?.provenance?.claudeCodeToolName;
  if (
    tool?.status !== "completed" ||
    typeof name !== "string" ||
    !PLUMBING_TOOLS.has(name) ||
    tool.title !== name
  )
    return false;
  // A discovery call that reports an error remains visible and counts as work. Keep this
  // predicate aligned with the presentation projection in mcpPresentation.ts.
  if (
    (tool.exitCode ?? 0) !== 0 ||
    /(?:"(?:isError|error)"\s*:\s*(?!(?:false|null|0)\s*[,}])\S|"(?:success|ok)"\s*:\s*(?:false|0)\b|"(?:status|state)"\s*:\s*"(?:error|failed|cancelled|canceled)"|^\s*(?:error|failed|unable|unavailable|cancelled|canceled)(?:\s+by\s+user)?\b)/im.test(
      tool.output ?? "",
    )
  )
    return false;
  return true;
}

/// Whether an ACP tool call or update is Muse Code's own todo tool, whose list the cmux-muse-acp
/// adapter also sends as an ACP `plan` (`session/todoListChanged`, its src/acp.rs `send_plan`), so
/// the checklist stands for the call. Only the adapter's top-level `name` counts, which carries
/// Muse's tool name verbatim (its src/fold.rs `tool_line`); a title alone could be any tool's.
export function isMuseTodoCall(update: any): boolean {
  return update?.name === "write_todos";
}

/// Tracks which call ids in `hidden` are plumbing and says whether this update's call is one. A
/// plumbing call marks its id; any other call that starts under that id clears the mark, since an
/// adapter that numbers calls per process reuses an id in a later prompt (cx-jzhka). A result
/// (`tool_call_update`, which names no tool) keeps whatever mark its call left.
export function hiddenCall(hidden: Set<string>, key: string, update: any): boolean {
  if (isPlumbingCall(update)) hidden.add(key);
  else if (update?.sessionUpdate === "tool_call") hidden.delete(key);
  return hidden.has(key);
}

/// Whether a tool name (Claude's `last_tool_name` in a subagent's progress) is plumbing.
export function isPlumbingName(name: unknown): boolean {
  return typeof name === "string" && PLUMBING_TOOLS.has(name.trim());
}

/// Whether a `tool_call_update` for a call this view never saw has nothing a row could stand on:
/// no title, name or kind, and no file it touched (a place, a diff) or image. Its row would be
/// titled with the raw call id over at most some text. It is what a page that starts between a
/// call and its result holds: acpmux sends a result (ToolSearch's included, an error's text too)
/// without the tool's name, so a hidden call's result cannot be told from another's. A subagent's
/// view already drops every such update (subagents/childRows.ts); the parent keeps only those
/// that carry a file change or an image.
export function showsNothing(update: any): boolean {
  if (update?.title || update?.name || update?.kind) return false;
  if (Array.isArray(update?.locations) && update.locations.length) return false;
  const content = update?.content;
  if (!Array.isArray(content)) return true;
  return !content.some((part: any) => part?.type === "diff" || part?.content?.type === "image");
}
