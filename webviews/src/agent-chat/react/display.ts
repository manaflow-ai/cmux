// Pure display helpers for the agent-chat timeline.

import type { AgentSessionRef, ConversationItem, ItemType } from "../protocol";

export function providerDisplayName(provider: string | undefined): string {
  if (!provider) {
    return "Agent";
  }
  if (provider === "claude") {
    return "Claude";
  }
  if (provider === "codex") {
    return "Codex";
  }
  return provider.charAt(0).toUpperCase() + provider.slice(1);
}

export function sessionDisplayTitle(session: AgentSessionRef | null): string {
  if (!session) {
    return "Agent session";
  }
  if (session.title && session.title.trim() !== "") {
    return session.title;
  }
  const transcriptFile = session.transcript_path.split("/").pop();
  return transcriptFile || session.session_id;
}

const toolTypeLabels: Partial<Record<ItemType, string>> = {
  command_execution: "Run",
  file_change: "Edit",
  mcp_tool_call: "MCP",
  dynamic_tool_call: "Tool",
  web_search: "Search",
};

export function isToolItemType(type: ItemType): boolean {
  return type in toolTypeLabels;
}

export function toolTypeLabel(type: ItemType): string {
  return toolTypeLabels[type] ?? "Tool";
}

export function toolItemTitle(item: ConversationItem): string {
  return item.title || item.tool_name || toolTypeLabel(item.type);
}

const toolTypeGlyphs: Partial<Record<ItemType, string>> = {
  command_execution: "$",
  file_change: "±",
  mcp_tool_call: "⚙",
  dynamic_tool_call: "⚙",
  web_search: "⌕",
};

export function toolTypeGlyph(type: ItemType): string {
  return toolTypeGlyphs[type] ?? "⚙";
}

export function formatToolInput(input: unknown): string {
  if (input === undefined || input === null) {
    return "";
  }
  if (typeof input === "string") {
    return input;
  }
  try {
    return JSON.stringify(input, null, 2) ?? String(input);
  } catch {
    return String(input);
  }
}

export function statusGlyph(status: ConversationItem["status"]): string {
  switch (status) {
    case "completed":
      return "✓";
    case "failed":
      return "✕";
    case "declined":
      return "⊘";
    case "in_progress":
      return "";
  }
}
