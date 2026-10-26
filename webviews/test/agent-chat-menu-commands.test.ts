import { expect, test } from "bun:test";
import { isCurrentMenuCommand, parseMenuCommand } from "../src/agent-session/acpmux/header/menuCommands";

test("menu commands carry an action and focused session", () => {
  const command = "menu:toggleDisplaySettings|chat-123";
  expect(parseMenuCommand(command)).toEqual({ action: "toggleDisplaySettings", sessionId: "chat-123" });
  expect(isCurrentMenuCommand(command, "chat-123")).toBe(true);
  expect(isCurrentMenuCommand(command, "chat-456")).toBe(false);
});

test("malformed or empty-session menu commands are dropped", () => {
  for (const value of [undefined, "toggleDisplaySettings", "menu:|chat-123", "menu:replay|"]) {
    expect(parseMenuCommand(value)).toBeUndefined();
  }
});
