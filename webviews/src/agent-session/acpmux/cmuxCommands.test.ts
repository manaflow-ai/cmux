import { describe, expect, test } from "bun:test";
import { CMUX_COMMANDS, commandArgs, continueTargets, mergedCommands, resolveHarnessTarget } from "./cmuxCommands";

describe("cmux slash commands", () => {
  test("merges cmux commands before harness commands and deduplicates names", () => {
    const commands = mergedCommands([
      { name: "import", description: "agent import", source: "agent" },
      { name: "compact", description: "agent compact", source: "agent" },
    ]);
    expect(commands.map((command) => command.name)).toEqual(["import", "continue", "compact"]);
    expect(commands[0]?.source).toBe("cmux");
    expect(commands[1]?.source).toBe("cmux");
  });

  test("extracts optional command arguments", () => {
    expect(commandArgs("/import", CMUX_COMMANDS[0]!)).toBe("");
    expect(commandArgs("/import session.jsonl", CMUX_COMMANDS[0]!)).toBe("session.jsonl");
    expect(commandArgs("say /import", CMUX_COMMANDS[0]!)).toBeUndefined();
  });

  test("resolves continue targets by id or visible name and rejects extra words", () => {
    const targets = [
      { id: "codex", name: "Codex" },
      { id: "claude", name: "Claude Code" },
    ];
    expect(resolveHarnessTarget("codex", targets)).toEqual(targets[0]);
    expect(resolveHarnessTarget("Claude Code", targets)).toEqual(targets[1]);
    expect(resolveHarnessTarget("codex now", targets)).toBeUndefined();
    expect(resolveHarnessTarget("", targets)).toBeUndefined();
  });

  test("offers every available harness except the one already running", () => {
    const targets = continueTargets(
      [
        { id: "claude-sr", name: "Claude Code" },
        { id: "codex", name: "Codex" },
        { id: "opencode", name: "OpenCode", unavailable: "not installed" },
        { id: "folder-agent", name: "Folder Agent", pickable: false },
      ],
      "claude-sr",
    );
    expect(targets.map((target) => target.id)).toEqual(["codex"]);
  });
});
