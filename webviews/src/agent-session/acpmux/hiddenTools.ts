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

/// Whether a `tool_call_update` for a call this view never saw has nothing a row could show: no
/// title, kind, input, output, place, diff, image or text. Such a row would read as its raw call
/// id. It is what a page that starts between a call and its result holds for a hidden call:
/// acpmux sends ToolSearch's result (its schemas are `tool_reference` blocks, no text) and a
/// withdrawn call's failure without the tool's name.
export function showsNothing(update: any): boolean {
  if (update?.title || update?.name || update?.kind) return false;
  if (update?.rawInput !== undefined || update?.rawOutput !== undefined) return false;
  if (Array.isArray(update?.locations) && update.locations.length) return false;
  const content = update?.content;
  if (content === undefined || content === null) return true;
  if (!Array.isArray(content)) return false;
  return content.every(
    (part: any) =>
      part?.type === "content" &&
      part.content?.type === "text" &&
      (typeof part.content.text !== "string" || !part.content.text.trim()),
  );
}
