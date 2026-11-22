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

/// What the chat menu knows of a chat's own auto-settle (acpmux `_acpmux/auto_settle`): `never`
/// is its Never Settle override, `on` whether any Settle Chats setting is on on its daemon.
export type AutoSettleState = { sessionId: string; never: boolean; on: boolean };

// The chat menu's Never Settle / Allow Settling (hub/auto_settle.rs, opt-in Settings > General >
// Settle Chats): sets or removes the chat's own `autoSettle=never`. Shown only while a settle
// setting is on, or on a chat already set to never (so it can be undone); with every setting off,
// the default, the menu is as before.
export function neverSettleRow(
  chat: { sessionId: string | undefined; archived: boolean; local: boolean },
  state: AutoSettleState | undefined,
  setNever: (never: boolean) => void,
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator"> | undefined {
  if (!chat.sessionId || !chat.local || chat.archived) return undefined;
  if (!state || state.sessionId !== chat.sessionId || !(state.on || state.never)) return undefined;
  return {
    key: "neverSettle",
    label: t(state.never ? "settle.allow" : "settle.never"),
    icon: "inbox",
    onSelect: () => setNever(!state.never),
  };
}
