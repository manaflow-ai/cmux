// What fills a chat's context window, by kind, for the context ring's card (ContextCard.tsx).
// The numbers are Claude Code's own /context rows: acpmux asks Claude Code's `get_context_usage`
// after each turn and forwards the answer on a `usage_update` as `_meta.claude.context`
// (claude_stdio/inbound.rs). Codex and a Claude Code that predates the request report no
// breakdown, and the card then shows only the totals: no row is ever estimated.

/// One of Claude Code's /context rows, as acpmux forwards it.
export type ContextCategory = { id?: string; name: string; tokens: number };

/// Claude Code's breakdown of the window, as acpmux forwards it.
export type ContextBreakdown = {
  categories: ContextCategory[];
  /// Files attached to prompts (Claude Code's `messageBreakdown.attachmentTokens`).
  attachmentTokens?: number;
  /// What each tool's results take, by tool name (`messageBreakdown.toolCallsByType`).
  toolResults?: Array<{ name: string; tokens: number }>;
};

/// The card's rows, in the bar's order.
export type ContextPartKind = "system" | "tools" | "files" | "messages";
export type ContextPart = { kind: ContextPartKind; tokens: number };

// Claude Code's row ids (stable where its English names are not), folded into the card's rows.
const KIND_BY_ID: Record<string, ContextPartKind> = {
  system_prompt: "system",
  mcp_instructions: "system",
  custom_agents: "system",
  skills: "system",
  system_tools: "tools",
  mcp_tools: "tools",
  memory_files: "files",
  messages: "messages",
};
// A Claude Code that predates the ids names its rows only.
const KIND_BY_NAME: Record<string, ContextPartKind> = {
  "System prompt": "system",
  "MCP instructions": "system",
  "Custom agents": "system",
  Skills: "system",
  "System tools": "tools",
  "MCP tools": "tools",
  "Memory files": "files",
  Messages: "messages",
};
/// Tools whose results are the contents of files.
const FILE_TOOLS = new Set(["Read", "NotebookRead"]);

const count = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.round(value) : undefined;

/// The breakdown a usage update carries (`_meta.claude.context`), or undefined when it carries
/// none or a malformed one.
export function contextBreakdownOf(update: unknown): ContextBreakdown | undefined {
  const meta = (update as { _meta?: { claude?: { context?: unknown } } } | undefined)?._meta;
  const raw = meta?.claude?.context as
    | { categories?: unknown; attachmentTokens?: unknown; toolResults?: unknown }
    | undefined;
  if (!raw || !Array.isArray(raw.categories)) return undefined;
  const categories: ContextCategory[] = [];
  for (const entry of raw.categories as Array<Record<string, unknown>>) {
    const tokens = count(entry?.tokens);
    if (typeof entry?.name !== "string" || tokens === undefined) continue;
    categories.push({ ...(typeof entry.id === "string" ? { id: entry.id } : {}), name: entry.name, tokens });
  }
  if (categories.length === 0) return undefined;
  const toolResults = Array.isArray(raw.toolResults)
    ? (raw.toolResults as Array<Record<string, unknown>>).flatMap((entry) => {
        const tokens = count(entry?.tokens);
        return typeof entry?.name === "string" && tokens !== undefined ? [{ name: entry.name, tokens }] : [];
      })
    : undefined;
  const attachmentTokens = count(raw.attachmentTokens);
  return {
    categories,
    ...(attachmentTokens !== undefined ? { attachmentTokens } : {}),
    ...(toolResults ? { toolResults } : {}),
  };
}

/// The card's rows from a breakdown and the tokens used now: system (the system prompt, agents,
/// skills and MCP instructions), tools (built-in and MCP tool definitions), files (memory files
/// such as CLAUDE.md, attached files and what Read returned) and messages, which is the rest of
/// what is used now, so the rows add up to the ring's number while a turn grows the conversation
/// past the last breakdown. A row with no tokens is left out.
export function contextParts(used: number, breakdown: ContextBreakdown | undefined): ContextPart[] {
  if (!breakdown) return [];
  const sums: Record<ContextPartKind, number> = { system: 0, tools: 0, files: 0, messages: 0 };
  for (const category of breakdown.categories) {
    const kind = (category.id ? KIND_BY_ID[category.id] : undefined) ?? KIND_BY_NAME[category.name];
    if (kind) sums[kind] += category.tokens;
  }
  // Attachments and file reads sit inside Claude Code's Messages row: they move to files.
  const fileResults = (breakdown.toolResults ?? [])
    .filter((tool) => FILE_TOOLS.has(tool.name))
    .reduce((sum, tool) => sum + tool.tokens, 0);
  sums.files += (breakdown.attachmentTokens ?? 0) + fileResults;
  sums.messages = Math.max(0, used - sums.system - sums.tools - sums.files);
  return (["system", "tools", "files", "messages"] as const)
    .map((kind) => ({ kind, tokens: sums[kind] }))
    .filter((part) => part.tokens > 0);
}

/// When the chat's last compaction finished (the session's clock), from the rows held: the newest
/// compaction row that completed. Undefined before one, or when it sits in history not loaded.
export function lastCompactedAt(rows: ReadonlyArray<{ kind: string; endedAt?: number }>): number | undefined {
  for (let index = rows.length - 1; index >= 0; index--) {
    const row = rows[index]!;
    if (row.kind === "compaction" && row.endedAt !== undefined) return row.endedAt;
  }
  return undefined;
}
