import { expect, test } from "bun:test";
import { contextBreakdown } from "./contextSectionModel";

const category = (id: string | undefined, name: string, tokens: number, kind: string) => ({
  ...(id ? { id } : {}),
  name,
  tokens,
  kind,
});

test("used categories take Claude Code desktop's hues by id, or by name where /context sent none", () => {
  const breakdown = contextBreakdown({
    maxTokens: 1_000_000,
    categories: [
      category("messages", "Messages", 21_800, "used"),
      category(undefined, "MCP tools", 17_900, "used"),
      category("system_prompt", "System prompt", 10_100, "used"),
      category("skills", "Skills", 10_000, "used"),
      category("memory_files", "Memory files", 6_500, "used"),
      category("custom_agents", "Custom agents", 601, "used"),
    ],
  });
  expect(breakdown?.rows.map((row) => [row.name, row.hue])).toEqual([
    ["Messages", "messages"],
    ["MCP tools", "mcpTools"],
    ["System prompt", "systemPrompt"],
    ["Skills", "skills"],
    ["Memory files", "other"],
    ["Custom agents", "other"],
  ]);
});

test("rows come as Claude's: used largest first, the buffer, the free space, then the deferred ones", () => {
  const breakdown = contextBreakdown({
    maxTokens: 1_000_000,
    categories: [
      category("mcp_tools_deferred", "MCP tools (deferred)", 101_900, "deferred"),
      category("free_space", "Free space", 896_000, "free"),
      category("autocompact_buffer", "Autocompact buffer", 33_000, "buffer"),
      category("skills", "Skills", 10_000, "used"),
      category("messages", "Messages", 21_800, "used"),
    ],
  });
  expect(breakdown?.rows.map((row) => [row.name, row.hue, row.share])).toEqual([
    ["Messages", "messages", 0.0218],
    ["Skills", "skills", 0.01],
    ["Autocompact buffer", undefined, 0.033],
    ["Free space", undefined, 0.896],
    ["MCP tools (deferred)", undefined, undefined],
  ]);
});
