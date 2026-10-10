import { describe, expect, test } from "bun:test";
import { CMUX_COMMANDS, commandArgs, continueTargets, resolveHarnessTarget } from "./cmuxCommands";

describe("cmux slash commands", () => {
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
