import { expect, test } from "bun:test";
import { mergedCommands } from "./cmuxCommands";

test("status is available before harness commands and stays cmux-owned", () => {
  const commands = mergedCommands([
    { name: "status", description: "agent status", source: "agent" },
    { name: "compact", description: "Compact context", source: "agent" },
  ]);

  expect(commands.map((command) => command.name)).toEqual([
    "model",
    "fast",
    "context",
    "plan",
    "import",
    "continue",
    "fork",
    "btw",
    "side",
    "status",
    "compact",
    // Not advertised by this harness: cmux's passthrough fallback, after the harness's own.
    "clear",
  ]);
  expect(commands.find((command) => command.name === "status")?.source).toBe("cmux");
  expect(commands.find((command) => command.name === "side")).toMatchObject({
    source: "cmux",
    action: "side",
    descriptionKey: "composer.slashSide",
  });
});

test("status can be disabled while a pane is not ready", () => {
  const commands = mergedCommands([], new Set(["import"]));
  // The passthrough fallbacks stay: they are the harness's own commands, sent as typed.
  expect(commands.map((command) => command.name)).toEqual(["import", "compact", "clear"]);
});
