// The chat's "⋮" menu at the pane's top right, grouped by what a row does (Leo 2026-10-23: "the
// ellipsis section on the top right is bad too"): the chat itself, a new chat from it, what opens
// beside it (the quick actions folded out of the header included, no longer stacked above Rename),
// where the tab goes, how the chat shows, then Archive and Close. Every row that has an app action
// shows its key. No row is dropped.
import { expect, test } from "bun:test";
import type { ChatMenuItem } from "../src/agent-session/acpmux/header/ChatHeaderTools";
import { CHAT_MENU_FOLDED, chatMenuOrder, withFolded } from "../src/agent-session/acpmux/header/chatMenuOrder";
import { opensBesideRows } from "../src/agent-session/acpmux/header/sideChatRow";

const row = (key: string, shortcutAction?: string): Exclude<ChatMenuItem, "separator"> => ({
  key,
  label: key,
  icon: "folder",
  ...(shortcutAction ? { shortcutAction } : {}),
  onSelect: () => {},
});
const keys = (items: readonly (ChatMenuItem | typeof CHAT_MENU_FOLDED)[]) =>
  items.map((item) => (item === "separator" ? "|" : item === CHAT_MENU_FOLDED ? "<folded>" : item.key));

const full = {
  quick: false,
  rename: row("rename"),
  pin: row("pin"),
  markUnread: row("markUnread"),
  copy: row("copy"),
  sideChat: row("sideChat"),
  fork: row("fork"),
  continueIn: row("continue"),
  beside: [row("newTerminal"), row("newBrowser")],
  move: [row("moveRight"), row("newWorkspace"), row("newWindow"), row("floatingChat")],
  view: [row("display"), row("inspector"), row("replay"), row("instructions"), row("checkpoint")],
  archive: row("archive"),
  close: row("close"),
};

test("the chat menu groups its rows by what they do, in six groups", () => {
  expect(keys(chatMenuOrder(full))).toEqual([
    "rename",
    "pin",
    "markUnread",
    "copy",
    "|",
    "sideChat",
    "fork",
    "continue",
    "|",
    "<folded>",
    "newTerminal",
    "newBrowser",
    "|",
    "moveRight",
    "newWorkspace",
    "newWindow",
    "floatingChat",
    "|",
    "display",
    "inspector",
    "replay",
    "instructions",
    "checkpoint",
    "|",
    "archive",
    "close",
  ]);
});

test("Quick Chat's panel keeps the chat's own rows in the same order, nothing beside it", () => {
  expect(keys(chatMenuOrder({ quick: true, copy: row("copy"), fork: row("fork"), view: [row("display")] }))).toEqual([
    "copy",
    "|",
    "fork",
    "|",
    "display",
  ]);
});

test("the header's folded quick actions open beside the chat, after the chat's own rows", () => {
  const folded = [row("quick-changes"), row("quick-files")];
  expect(keys(withFolded(folded, chatMenuOrder(full)))).toEqual([
    "rename",
    "pin",
    "markUnread",
    "copy",
    "|",
    "sideChat",
    "fork",
    "continue",
    "|",
    "quick-changes",
    "quick-files",
    "newTerminal",
    "newBrowser",
    "|",
    "moveRight",
    "newWorkspace",
    "newWindow",
    "floatingChat",
    "|",
    "display",
    "inspector",
    "replay",
    "instructions",
    "checkpoint",
    "|",
    "archive",
    "close",
  ]);
});

test("an empty group leaves no separator, and a menu without the slot keeps the folded rows first", () => {
  const sparse = chatMenuOrder({ quick: false, rename: row("rename"), beside: [], view: [], close: row("close") });
  expect(keys(withFolded([], sparse))).toEqual(["rename", "|", "close"]);
  expect(keys(withFolded([row("quick-files")], sparse))).toEqual(["rename", "|", "quick-files", "|", "close"]);
  expect(keys(withFolded([row("quick-files")], [row("rename")]))).toEqual(["quick-files", "|", "rename"]);
  expect(keys(withFolded([], [row("rename")]))).toEqual(["rename"]);
});

test("New terminal and New browser show the keys of the splits they open", () => {
  const rows = opensBesideRows({ quick: false }, { terminal: () => {}, browser: () => {} });
  expect(rows.map((item) => [item.key, item.shortcutAction])).toEqual([
    ["newTerminal", "splitRight"],
    ["newBrowser", "splitBrowserRight"],
  ]);
});
