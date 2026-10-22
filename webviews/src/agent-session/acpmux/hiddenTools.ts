// Tool calls the transcript never draws: an agent's own plumbing, which does nothing the person
// asked for and shows nothing they could act on. Claude Code's ToolSearch only loads the schemas
// of deferred tools so it can call them; its row read as a bare "ToolSearch" with a grid icon
// (Leo 2026-10-21: "UI ALSO NEEDS TO BE BETTER"). Such a call draws no row, opens no fold and
// counts toward no "Worked for" summary, done or failed alike.

/// Claude Code tools that are pure plumbing, by their Claude Code name.
const PLUMBING_TOOLS: ReadonlySet<string> = new Set(["ToolSearch"]);

/// Whether an ACP `tool_call` is plumbing the transcript hides. Only a call named as Claude Code's
/// own tool counts (acpmux's `_meta.claude.tool`, the ACP adapter's `_meta.claudeCode.toolName`):
/// a title alone could be any other agent's or MCP server's tool.
export function isPlumbingCall(update: any): boolean {
  const tool = update?._meta?.claude?.tool ?? update?._meta?.claudeCode?.toolName;
  return typeof tool === "string" && PLUMBING_TOOLS.has(tool);
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
