import { describe, expect, test } from "bun:test";
import { commandWaitsForTurn } from "./cliOnlyCommands";

// Leo's chat, 2026-10-31: Claude Code listed /loop (a skill) among its 88 commands, and a `/loop`
// steered into the running turn sat as an unread steer until Claude Code's running command ended.
const commands = [{ name: "loop" }, { name: "compact" }, { name: "cmux:acpmux" }];

describe("commandWaitsForTurn", () => {
  test("a listed command, bare or with arguments, waits for the turn in a Claude chat", () => {
    expect(commandWaitsForTurn("/loop", "claude", commands)).toBe(true);
    expect(commandWaitsForTurn("/loop keep launching new dev builds", "claude", commands)).toBe(true);
    expect(commandWaitsForTurn("  /Compact\n", "claude", commands)).toBe(true);
    expect(commandWaitsForTurn("/cmux:acpmux ls", "claude-sr", commands)).toBe(true);
  });

  test("text that only starts with a slash steers as before", () => {
    expect(commandWaitsForTurn("/tmp is full, clean it", "claude", commands)).toBe(false);
    expect(commandWaitsForTurn("/Users/leo/a.txt explain this", "claude", commands)).toBe(false);
    expect(commandWaitsForTurn("/loopy", "claude", commands)).toBe(false);
    expect(commandWaitsForTurn("please /loop", "claude", commands)).toBe(false);
  });

  test("other harnesses and a chat with no command list are unchanged", () => {
    expect(commandWaitsForTurn("/loop", "codex", commands)).toBe(false);
    expect(commandWaitsForTurn("/loop", undefined, commands)).toBe(false);
    expect(commandWaitsForTurn("/loop", "claude", undefined)).toBe(false);
    expect(commandWaitsForTurn("/loop", "claude", [])).toBe(false);
  });
});
