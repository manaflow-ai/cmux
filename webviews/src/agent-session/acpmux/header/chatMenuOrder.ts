// The chat's "⋮" menu at the pane's top right, grouped by what a row does (Leo 2026-10-23: "the
// ellipsis section on the top right is bad too"). It was seven groups that began with the header's
// folded quick actions above Rename and split what opens beside the chat across two of them. Now:
//   1. the chat itself: Rename, Pin, Mark as Unread, Copy ›
//   2. a new chat from it: New side chat, Fork ›, Continue in ›
//   3. beside it: the folded quick actions (Changes, Preview, New tab, Files, Split Down), New
//      terminal, New browser
//   4. where the tab goes: Move to right pane, Move to new workspace, Open in new window, Floating chat
//   5. how the chat shows: Display, Inspector, Replay, Instructions, Project files, Checkpoint
//   6. Archive, then Close, last as in Chrome's tab menu.
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
  move?: Row[];
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

/// The menu's rows in their groups, with the folded quick actions' place in the beside group.
export function chatMenuOrder(parts: ChatMenuParts): ChatMenuEntry[] {
  const chat = present(parts.rename, parts.pin, parts.markUnread, parts.copy);
  const start = present(parts.sideChat, parts.fork, parts.continueIn);
  const view = parts.view ?? [];
  if (parts.quick) return menuGroups<ChatMenuEntry>(chat, start, view);
  const beside: ChatMenuEntry[] = [CHAT_MENU_FOLDED, ...(parts.beside ?? [])];
  const end = present(parts.archive, parts.close);
  return menuGroups<ChatMenuEntry>(chat, start, beside, parts.move ?? [], view, end);
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
