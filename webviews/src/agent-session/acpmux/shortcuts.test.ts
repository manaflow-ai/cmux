import { expect, test } from "bun:test";
import { readShortcuts, withShortcut } from "./shortcuts";

test("the host's shortcut payload keeps only keycap strings", () => {
  expect(readShortcuts({ "agentPane.searchChats": "⌘K", "palette.newAgentChat": "⇧⌘I" })).toEqual({
    "agentPane.searchChats": "⌘K",
    "palette.newAgentChat": "⇧⌘I",
  });
  expect(readShortcuts({ a: "", b: 3, c: null, d: "⌃⌘V" })).toEqual({ d: "⌃⌘V" });
  expect(readShortcuts(null)).toEqual({});
  expect(readShortcuts(["⌘K"])).toEqual({});
  expect(readShortcuts("⌘K")).toEqual({});
});

test("a tooltip names its shortcut only when there is one", () => {
  expect(withShortcut("Search chats", "⌘K")).toBe("Search chats (⌘K)");
  expect(withShortcut("Search chats", undefined)).toBe("Search chats");
});
