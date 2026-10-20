// Which glyph a tool row draws, and the names of the calls whose title says nothing: an agent
// call reads as its task ("Review the PR"), an MCP call as "server: tool name", and no row reads
// as a raw call id (`toolu_…`, `call_…`).
import type { AcpmuxActivity } from "../model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

export type ToolGlyph = "shell" | "read" | "edit" | "search" | "web" | "agent" | "mcp" | "other";

/// Claude Code's subagent tools; other harnesses mark one by a `subagent_type` in its input.
const AGENT_TOOLS = new Set(["Task", "Agent"]);
/// `mcp__github__get_issue` (Claude Code), or a title ending `(MCP)`.
const MCP_NAME = /^mcp__(.+?)__(.+)$/;

export function toolGlyph(tool: Tool): ToolGlyph {
  if (isAgentCall(tool)) return "agent";
  if (MCP_NAME.test(tool.name ?? tool.title) || /\(MCP\)\s*$/.test(tool.title)) return "mcp";
  if (tool.kind === "execute" && !tool.command) return "other";
  return kindGlyph(tool.kind);
}

/// An ACP tool kind's glyph (`ToolKind`), for a call known only by its kind (a permission ask).
export function kindGlyph(kind?: string): ToolGlyph {
  switch (kind) {
    case "read":
      return "read";
    case "edit":
    case "delete":
    case "move":
    case "fileChange":
      return "edit";
    case "search":
      return "search";
    case "execute":
      return "shell";
    case "fetch":
      return "web";
    default:
      return "other";
  }
}

export function isAgentCall(tool: Tool): boolean {
  if (tool.name && AGENT_TOOLS.has(tool.name)) return true;
  return typeof input(tool)?.subagent_type === "string";
}

/// An agent call's task: its description, else its name or subagent type.
export function agentLabel(tool: Tool): string | undefined {
  const fields = input(tool);
  for (const key of ["description", "name", "subagent_type"]) {
    const value = fields?.[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  const title = tool.title.trim();
  return title && !isCallId(title, tool) && !AGENT_TOOLS.has(title) ? title : undefined;
}

/// "github: get issue" for `mcp__github__get_issue`.
export function mcpLabel(tool: Tool): string | undefined {
  const match = MCP_NAME.exec(tool.title.trim()) ?? MCP_NAME.exec(tool.name ?? "");
  return match ? `${match[1]}: ${match[2]!.replace(/_/g, " ")}` : undefined;
}

/// A call's id standing in for its title.
export function isCallId(value: string, tool: Tool): boolean {
  return value === tool.id || /^(?:toolu_[A-Za-z0-9]{12,}|call_[A-Za-z0-9]{16,})$/.test(value);
}

function input(tool: Tool): Record<string, unknown> | undefined {
  if (!tool.inputSummary) return undefined;
  try {
    const value: unknown = JSON.parse(tool.inputSummary);
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}
