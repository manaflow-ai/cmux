import { expect, test } from "bun:test";
import { mergedCommands } from "./cmuxCommands";

test("status is available before harness commands and stays cmux-owned", () => {
  const commands = mergedCommands([
    { name: "status", description: "agent status", source: "agent" },
    { name: "compact", description: "Compact context", source: "agent" },
  ]);

  expect(commands.map((command) => command.name)).toEqual(["import", "continue", "fork", "btw", "side", "status", "compact"]);
  expect(commands.find((command) => command.name === "status")?.source).toBe("cmux");
  expect(commands.find((command) => command.name === "side")).toMatchObject({
    source: "cmux",
    action: "side",
    descriptionKey: "composer.slashFork",
  });
});

test("status can be disabled while a pane is not ready", () => {
  const commands = mergedCommands([], new Set(["import"]));
  expect(commands.map((command) => command.name)).toEqual(["import"]);
});
