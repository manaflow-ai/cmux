import { describe, expect, test } from "bun:test";
import { commandWaitsForTurn } from "./cliOnlyCommands";

// Leo's chat, 2026-10-31: Claude Code listed /loop (a skill) among its 88 commands, and a `/loop`
// steered into the running turn sat as an unread steer until Claude Code's running command ended.
const commands = [{ name: "mcp__github__list_prs" }, { name: "loop" }, { name: "compact" }, { name: "cmux:acpmux" }];

describe("commandWaitsForTurn", () => {
  test("a listed command, bare or with arguments, waits for the turn in a Claude chat", () => {
    expect(commandWaitsForTurn("/loop", "claude", commands)).toBe(true);
    expect(commandWaitsForTurn("/loop keep launching new dev builds", "claude", commands)).toBe(true);
    expect(commandWaitsForTurn("  /Compact\n", "claude", commands)).toBe(true);
    expect(commandWaitsForTurn("/cmux:acpmux ls", "claude-sr", commands)).toBe(true);
    // As the composer holds it: Markdown, with the typed underscores escaped.
    expect(commandWaitsForTurn("/mcp\\_\\_github\\_\\_list\\_prs", "claude", commands)).toBe(true);
  });

  test("text that only starts with a slash steers as before", () => {
    expect(commandWaitsForTurn("/tmp is full, clean it", "claude", commands)).toBe(false);
    expect(commandWaitsForTurn("/Users/leo/a.txt explain this", "claude", commands)).toBe(false);
    expect(commandWaitsForTurn("/loopy", "claude", commands)).toBe(false);
    expect(commandWaitsForTurn("please /loop", "claude", commands)).toBe(false);
  });

  test("cmux's own commands in the same list keep their send", () => {
    const merged = [...commands, { name: "model", source: "cmux" }, { name: "plan", source: "cmux" }];
    expect(commandWaitsForTurn("/model opus", "claude", merged)).toBe(false);
    expect(commandWaitsForTurn("/plan explain", "claude", merged)).toBe(false);
    expect(commandWaitsForTurn("/loop", "claude", merged)).toBe(true);
  });

  test("other harnesses and a chat with no command list are unchanged", () => {
    expect(commandWaitsForTurn("/loop", "codex", commands)).toBe(false);
    expect(commandWaitsForTurn("/loop", undefined, commands)).toBe(false);
    expect(commandWaitsForTurn("/loop", "claude", undefined)).toBe(false);
    expect(commandWaitsForTurn("/loop", "claude", [])).toBe(false);
  });
});
