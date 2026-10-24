// The chat's tools as acpmux reports them on its session (`tools`, `toolsMutable`; acpmux
// hub/tools.rs, cx-thur3): cmux's own, then the MCP servers, plugins and skills its harness
// reported. `_acpmux/set_tools` turns one on or off for this chat (direct.ts `setTool`); the
// Sources + menu's Use tools lists them (summary/SourcesAddMenu.tsx).

export type ChatToolKind = "cmux" | "mcp" | "plugin" | "skill";

export type ChatTool = {
  /// `mcp:<server>`, `skill:<name>` or `plugin:<name>`, unique in the chat.
  id: string;
  name: string;
  kind: ChatToolKind;
  /// What gives it: `cmux`, or the harness that reported it (`claude`).
  source: string;
  enabled: boolean;
  /// `_acpmux/set_tools` can turn it on or off in this chat.
  canToggle: boolean;
};

/// When a change applies: at once (an idle chat restarts and resumes), when the running turn
/// ends, or when the chat next starts.
export type ToolApplied = "now" | "afterTurn" | "nextStart";

/// The menu's order: cmux's own first, then MCP servers, plugins and skills.
export const TOOL_KINDS: readonly ChatToolKind[] = ["cmux", "mcp", "plugin", "skill"];

const isKind = (value: unknown): value is ChatToolKind => TOOL_KINDS.includes(value as ChatToolKind);

/// acpmux's `tools`, keeping only well-formed rows of a kind the page knows.
export function chatTools(value: unknown): ChatTool[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.flatMap((row): ChatTool[] => {
    if (!row || typeof row !== "object") return [];
    const { id, name, kind, source, enabled, canToggle } = row as Record<string, unknown>;
    if (typeof id !== "string" || !id || !isKind(kind)) return [];
    return [
      {
        id,
        name: typeof name === "string" && name ? name : id,
        kind,
        source: typeof source === "string" ? source : "",
        enabled: enabled !== false,
        canToggle: canToggle === true,
      },
    ];
  });
}

/// acpmux's `applied`.
export const toolApplied = (value: unknown): ToolApplied =>
  value === "afterTurn" || value === "nextStart" ? value : "now";
