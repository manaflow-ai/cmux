// The chat menu's Archive row: the pane asks acpmux to archive the chat (`_acpmux/archive`, the
// `archived` tag) over its own connection, then asks the app to close the tab; an archived chat
// opened from search offers Unarchive.
import { type Translate, translate } from "../i18n";
import type { ChatMenuItem } from "./ChatHeaderTools";

export function archiveRow(
  chat: { sessionId: string | undefined; archived: boolean; local: boolean },
  archive: (archived: boolean) => void,
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator"> | undefined {
  // Only a session this Mac's acpmux holds can carry the tag.
  if (!chat.sessionId || !chat.local) return undefined;
  return {
    key: "archive",
    label: t(chat.archived ? "chatMenu.unarchive" : "chatMenu.archive"),
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
