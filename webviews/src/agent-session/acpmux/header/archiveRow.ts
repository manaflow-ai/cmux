// The chat menu's Archive row: archiving tags the chat `archived` in acpmux and closes its tab
// (the app does both, `chat.archive`); an archived chat opened from search offers Unarchive.
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
