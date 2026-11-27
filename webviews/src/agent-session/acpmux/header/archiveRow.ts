// The chat menu's Archive row: the pane asks acpmux to archive the chat (`_acpmux/archive`, the
// `archived` tag) over its own connection, then asks the app to close the tab; an archived chat
// opened from search offers Unarchive, and a chat acpmux settled (archived with a reason,
// hub/auto_settle.rs) offers the same row as Unsettle, which drops the reason too.
import { type Translate, translate } from "../i18n";
import type { ChatMenuItem } from "./chatHeaderToolsModel";

export function archiveRow(
  chat: { sessionId: string | undefined; archived: boolean; local: boolean; settled?: boolean },
  archive: (archived: boolean) => void,
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator"> | undefined {
  // Only a session this Mac's acpmux holds can carry the tag.
  if (!chat.sessionId || !chat.local) return undefined;
  return {
    key: "archive",
    label: t(chat.archived ? (chat.settled ? "settle.unsettle" : "chatMenu.unarchive") : "chatMenu.archive"),
    icon: "inbox",
    onSelect: () => archive(!chat.archived),
  };
}

// The chat menu's Mark as Unread (cx-ncc.78, Codex parity): the pane asks acpmux to mark the chat
// unread (`_acpmux/markUnread`), and it stays unread until the chat is hidden and shown again.
export function markUnreadRow(
  chat: { sessionId: string | undefined; archived: boolean; local: boolean; unread: boolean },
  markUnread: () => void,
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator"> | undefined {
  if (!chat.sessionId || !chat.local || chat.archived || chat.unread) return undefined;
  return { key: "markUnread", label: t("chatMenu.markUnread"), icon: "unread.dot", onSelect: markUnread };
}
