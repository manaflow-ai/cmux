// The chat menu's one ladder: Messages, Normal, Thinking, Verbose, then Make … the default.
import { afterEach, expect, test } from "bun:test";
import { chatDisplayValues, resetChatDisplayForTests } from "../chatDisplay";
import { chatDetailOf, resetChatDetails } from "../conversation/chatDetailChoice";
import { translate } from "../i18n";
import { chatDetailRow } from "./chatDetailRow";

afterEach(() => {
  resetChatDetails();
  resetChatDisplayForTests();
});

test("the menu shows the four levels in order and checks this chat's", () => {
  const row = chatDetailRow("chat", translate)!;
  const levels = row.children!.filter((child) => child.key.startsWith("detail.") && child.key !== "detail.default");
  expect(levels.map((child) => child.key)).toEqual([
    "detail.messages",
    "detail.normal",
    "detail.thinking",
    "detail.verbose",
  ]);
  expect(levels.find((child) => child.checked)?.key).toBe("detail.normal");
  expect(levels.every((child) => !child.disabled)).toBe(true);
});

test("picking a level changes this chat only; Make default writes the setting", () => {
  chatDetailRow("chat", translate)!
    .children!.find((child) => child.key === "detail.messages")!
    .onSelect();
  expect(chatDetailOf("chat")).toBe("messages");
  expect(chatDetailOf("other")).toBe("normal");
  chatDetailRow("chat", translate)!
    .children!.find((child) => child.key === "detail.default")!
    .onSelect();
  expect(chatDisplayValues()["agentPane.display.detail"]).toBe("messages");
  expect(chatDetailOf("other")).toBe("messages");
  expect(chatDetailRow(undefined, translate)).toBeUndefined();
});
