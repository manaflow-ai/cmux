// What fills the context window, for the context ring's card: Claude Code's /context rows as acpmux
// forwards them on a usage update (`_meta.claude.context`), folded into the card's four rows
// (system, tools, files, messages). Nothing is estimated: no breakdown, no rows.
import { expect, test } from "bun:test";
import { contextBreakdownOf, contextParts } from "./contextBreakdown";

/// Claude Code 2.1.305's `get_context_usage` rows for a chat 111K into a 475K window, as acpmux
/// forwards them (claude_stdio/inbound.rs `context_breakdown`).
const CLAUDE_CONTEXT = {
  categories: [
    { id: "system_prompt", name: "System prompt", tokens: 6_200 },
    { id: "system_tools", name: "System tools", tokens: 14_300 },
    { id: "mcp_tools", name: "MCP tools", tokens: 3_100 },
    { id: "mcp_instructions", name: "MCP instructions", tokens: 400 },
    { id: "custom_agents", name: "Custom agents", tokens: 900 },
    { id: "memory_files", name: "Memory files", tokens: 4_800 },
    { id: "skills", name: "Skills", tokens: 1_600 },
    { id: "messages", name: "Messages", tokens: 70_000 },
    { id: "autocompact_buffer", name: "Autocompact buffer", tokens: 45_000 },
    { id: "free_space", name: "Free space", tokens: 318_700 },
  ],
  attachmentTokens: 2_500,
  toolResults: [
    { name: "Read", tokens: 9_000 },
    { name: "Bash", tokens: 6_000 },
  ],
};
const update = (context: unknown) => ({
  sessionUpdate: "usage_update",
  used: 111_000,
  size: 475_000,
  _meta: { claude: { context } },
});

test("a usage update without Claude Code's rows carries no breakdown", () => {
  expect(contextBreakdownOf({ sessionUpdate: "usage_update", used: 1, size: 2 })).toBeUndefined();
  expect(contextBreakdownOf(update({ categories: "nope" }))).toBeUndefined();
  expect(contextBreakdownOf(update({ categories: [{ name: "Messages", tokens: -1 }] }))).toBeUndefined();
  // Codex's usage update carries its own token usage, never /context rows.
  expect(
    contextBreakdownOf({ sessionUpdate: "usage_update", used: 1, size: 2, _meta: { codexAppServer: {} } }),
  ).toBeUndefined();
});

test("Claude Code's rows fold into system, tools, files and messages", () => {
  const breakdown = contextBreakdownOf(update(CLAUDE_CONTEXT));
  expect(breakdown).toBeDefined();
  const parts = contextParts(111_000, breakdown);
  // System: prompt, MCP instructions, agents and skills. Tools: built-in and MCP tool definitions.
  // Files: memory files, attachments and what Read returned. Messages: the rest of what is used.
  expect(parts).toEqual([
    { kind: "system", tokens: 6_200 + 400 + 900 + 1_600 },
    { kind: "tools", tokens: 14_300 + 3_100 },
    { kind: "files", tokens: 4_800 + 2_500 + 9_000 },
    { kind: "messages", tokens: 111_000 - 9_100 - 17_400 - 16_300 },
  ]);
  // The rows add up to what the ring says is used; free space and the buffer are no row.
  expect(parts.reduce((sum, part) => sum + part.tokens, 0)).toBe(111_000);
});

test("a Claude Code that names its rows without ids still folds them", () => {
  const named = {
    categories: CLAUDE_CONTEXT.categories.map(({ name, tokens }) => ({ name, tokens })),
  };
  const parts = contextParts(111_000, contextBreakdownOf(update(named)));
  expect(parts.map((part) => part.kind)).toEqual(["system", "tools", "files", "messages"]);
  expect(parts.find((part) => part.kind === "files")?.tokens).toBe(4_800);
});

test("a row with no tokens is left out, and no breakdown means no rows", () => {
  const bare = { categories: [{ id: "system_prompt", name: "System prompt", tokens: 3_000 }] };
  expect(contextParts(3_000, contextBreakdownOf(update(bare)))).toEqual([{ kind: "system", tokens: 3_000 }]);
  expect(contextParts(111_000, undefined)).toEqual([]);
});
