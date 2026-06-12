// Pure display helpers for the agent-chat timeline.

import { agentChatLabels } from "../labels";
import type { AgentSessionRef, ConversationItem, ItemType } from "../protocol";

export function providerDisplayName(provider: string | undefined): string {
  if (!provider) {
    return agentChatLabels.providerFallback;
  }
  if (provider === "claude") {
    return agentChatLabels.providerClaude;
  }
  if (provider === "codex") {
    return agentChatLabels.providerCodex;
  }
  return provider.charAt(0).toUpperCase() + provider.slice(1);
}

export function sessionDisplayTitle(session: AgentSessionRef | null): string {
  if (!session) {
    return agentChatLabels.sessionFallbackTitle;
  }
  if (session.title && session.title.trim() !== "") {
    return session.title;
  }
  const transcriptFile = session.transcript_path.split("/").pop();
  return transcriptFile || session.session_id;
}

const toolTypeLabels: Partial<Record<ItemType, string>> = {
  command_execution: agentChatLabels.toolRun,
  file_change: agentChatLabels.toolEdit,
  mcp_tool_call: agentChatLabels.toolMCP,
  dynamic_tool_call: agentChatLabels.toolGeneric,
  web_search: agentChatLabels.toolSearch,
};

export function isToolItemType(type: ItemType): boolean {
  return type in toolTypeLabels;
}

export function toolTypeLabel(type: ItemType): string {
  return toolTypeLabels[type] ?? agentChatLabels.toolGeneric;
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
