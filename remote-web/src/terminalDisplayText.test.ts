import { expect, test } from "bun:test";
import { decoratePlainTerminalText } from "./terminalDisplayText";

test("dims common user input prompt lines", () => {
  const decorated = decoratePlainTerminalText("ready\n> hello\n$ ls\n\u203a explain this\nagent response");

  expect(decorated).toContain("\u001b[38;5;245m> hello\u001b[0m");
  expect(decorated).toContain("\u001b[38;5;245m$ ls\u001b[0m");
  expect(decorated).toContain("\u001b[38;5;245m\u203a explain this\u001b[0m");
  expect(decorated).toContain("agent response");
});

test("does not decorate existing ANSI output", () => {
  const text = "\u001b[32m> already styled\u001b[0m";
  expect(decoratePlainTerminalText(text)).toBe(text);
});
