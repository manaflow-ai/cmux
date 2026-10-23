// The chat's "⋮" menu at the pane's top right, grouped by what a row does (Leo 2026-10-23: "the
// ellipsis section on the top right is bad too"). It was about 25 rows in seven groups that began
// with the header's folded quick actions above Rename. Now five short groups:
//   1. the chat itself: Rename, Pin, Mark as Unread, Copy ›
//   2. a new chat from it: New side chat, Fork ›, Continue in ›
//   3. beside it: the folded quick actions (Changes, Preview, New tab, Files, Split Down), New
//      terminal, New browser
//   4. Move to › (Right pane, New workspace, New window, Floating chat) and Tools › (Text & Width,
//      Replay, Edit CLAUDE.md, Add Files to Project, ACP inspector, Create checkpoint)
//   5. Archive, then Close, last as in Chrome's tab menu.
// Quick Chat's panel is not a tab: the chat's own rows, its few tools inline.
import { type Translate, translate } from "../i18n";
import type { ChatMenuItem } from "./ChatHeaderTools";

type Row = Exclude<ChatMenuItem, "separator">;

/// Where ChatHeaderTools puts the quick actions it folds out of the header (``withFolded``).
export const CHAT_MENU_FOLDED = "folded" as const;

/// A row of the App's menu, or the folded quick actions' place.
export type ChatMenuEntry = ChatMenuItem | typeof CHAT_MENU_FOLDED;

export interface ChatMenuParts {
  /// Quick Chat's panel is not a tab: only the chat's own rows, nothing beside or moving it.
  quick: boolean;
  rename?: Row;
  pin?: Row;
  markUnread?: Row;
  copy?: Row;
  sideChat?: Row;
  fork?: Row;
  continueIn?: Row;
  /// New terminal and New browser (sideChatRow.ts opensBesideRows).
  beside?: Row[];
  /// Where the tab goes, folded into Move to ›.
  move?: Row[];
  /// How the chat shows and its tools, folded into Tools › (inline in Quick Chat).
  view?: Row[];
  archive?: Row;
  close?: Row;
}

/// The menu's groups in order, the empty ones dropped, with a separator between each two.
export const menuGroups = <T extends ChatMenuEntry>(...groups: T[][]): (T | "separator")[] =>
  groups
    .filter((group) => group.length > 0)
    .flatMap((group, index): (T | "separator")[] => (index ? ["separator", ...group] : group));

const present = (...rows: (Row | undefined)[]): Row[] => rows.filter((row): row is Row => row !== undefined);

/// A submenu of `rows` (their keys and keycaps kept), or nothing when they are none.
function submenu(key: string, label: string, icon: string, rows: readonly Row[]): Row[] {
  const children = rows.flatMap((row) =>
    row.onSelect && !row.disabled
      ? [{ key: row.key, label: row.label, shortcutAction: row.shortcutAction, onSelect: row.onSelect }]
      : [],
  );
  return children.length > 0 ? [{ key, label, icon, children }] : [];
}

/// The menu's rows in their groups, with the folded quick actions' place in the beside group.
export function chatMenuOrder(parts: ChatMenuParts, t: Translate = translate): ChatMenuEntry[] {
  const chat = present(parts.rename, parts.pin, parts.markUnread, parts.copy);
  const start = present(parts.sideChat, parts.fork, parts.continueIn);
  const view = parts.view ?? [];
  if (parts.quick) return menuGroups<ChatMenuEntry>(chat, start, view);
  const beside: ChatMenuEntry[] = [CHAT_MENU_FOLDED, ...(parts.beside ?? [])];
  const more = [
    ...submenu("moveTo", t("chatMenu.moveTo"), "pane.split.right", parts.move ?? []),
    ...submenu("tools", t("chatMenu.tools"), "code", view),
  ];
  const end = present(parts.archive, parts.close);
  return menuGroups<ChatMenuEntry>(chat, start, beside, more, end);
}

/// The menu with `folded` in its place; a menu without the place (a test's, a gallery fixture's)
/// lists them first. No separator leads, ends or repeats.
export function withFolded(folded: ChatMenuItem[], entries: readonly ChatMenuEntry[]): ChatMenuItem[] {
  const placed = entries.includes(CHAT_MENU_FOLDED)
    ? entries.flatMap((entry) => (entry === CHAT_MENU_FOLDED ? folded : [entry]))
    : menuGroups(
        folded,
        entries.filter((entry): entry is ChatMenuItem => entry !== CHAT_MENU_FOLDED),
      );
  return placed.filter(
    (item, index) =>
      item !== "separator" ||
      (index > 0 && index < placed.length - 1 && placed[index - 1] !== "separator" && hasRowAfter(placed, index)),
  );
}

const hasRowAfter = (items: readonly ChatMenuItem[], index: number) =>
  items.slice(index + 1).some((item) => item !== "separator");
