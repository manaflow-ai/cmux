import { expect, test } from "bun:test";
import { commandArgs, mergedCommands } from "../src/agent-session/acpmux/cmuxCommands";

test("/btw is in the shared slash completion for every harness", () => {
  const btw = mergedCommands([{ name: "review", description: "Review" }]).find((command) => command.name === "btw");
  expect(btw).toMatchObject({ name: "btw", source: "cmux", action: "btw" });
  expect(commandArgs("/btw Why did the retry test flake?", btw!)).toBe("Why did the retry test flake?");
});

test("a harness command with the same name cannot hide cmux /btw", () => {
  const commands = mergedCommands([{ name: "btw", description: "A harness command" }]);
  expect(commands.filter((command) => command.name === "btw")).toHaveLength(1);
  expect(commands[3]).toMatchObject({ name: "btw", source: "cmux" });
});
