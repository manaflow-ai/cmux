import { describe, expect, test } from "bun:test";
import { CMUX_COMMANDS, commandArgs, mergedCommands } from "./cmuxCommands";

describe("cmux slash commands", () => {
  test("merges cmux commands before harness commands and deduplicates names", () => {
    const commands = mergedCommands([
      { name: "import", description: "agent import", source: "agent" },
      { name: "compact", description: "agent compact", source: "agent" },
    ]);
    expect(commands.map((command) => command.name)).toEqual(["import", "compact"]);
    expect(commands[0]?.source).toBe("cmux");
  });

  test("extracts optional command arguments", () => {
    expect(commandArgs("/import", CMUX_COMMANDS[0]!)).toBe("");
    expect(commandArgs("/import session.jsonl", CMUX_COMMANDS[0]!)).toBe("session.jsonl");
    expect(commandArgs("say /import", CMUX_COMMANDS[0]!)).toBeUndefined();
  });
});
