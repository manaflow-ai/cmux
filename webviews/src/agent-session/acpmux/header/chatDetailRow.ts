// The chat menu's detail ladder (chatDetail.ts): Messages, Normal, Thinking and Verbose with a check
// on this chat's level, then "Make <level> the default", which writes the setting every chat without
// a level of its own follows (conversation/chatDetailChoice.ts). Home Channels' header shows the same
// four levels (pages/home-channels/presentation.tsx). `more` ends the submenu (Wrap lines, the chat's
// Text & Width…): the ··· menu is already full height, so the ladder takes no row of its own and
// Archive and Close stay on screen.
import type { StringKey, Translate } from "../i18n";
import { CHAT_DETAILS, type ChatDetail } from "../chatDetail";
import { defaultChatDetail } from "../chatDisplay";
import { chatDetailOf, hasOwnChatDetail, makeChatDetailDefault, setChatDetail } from "../conversation/chatDetailChoice";
import type { ChatMenuChild, ChatMenuItem } from "./chatHeaderToolsModel";

export const CHAT_DETAIL_NAMES: Record<ChatDetail, StringKey> = {
  messages: "chatMenu.presentation.messages",
  normal: "chatMenu.transcriptView.normal",
  thinking: "chatMenu.transcriptView.thinking",
  verbose: "chatMenu.transcriptView.verbose",
};

export function chatDetailRow(
  sessionId: string | undefined,
  t: Translate,
  more: readonly ChatMenuChild[] = [],
): Exclude<ChatMenuItem, "separator"> | undefined {
  if (!sessionId) return undefined;
  const level = chatDetailOf(sessionId);
  return {
    key: "transcriptView",
    label: t("chatMenu.transcriptView"),
    icon: "text.description",
    children: [
      ...CHAT_DETAILS.map((each) => ({
        key: `detail.${each}`,
        label: t(CHAT_DETAIL_NAMES[each]),
        checked: each === level,
        onSelect: () => setChatDetail(sessionId, each),
      })),
      {
        key: "detail.default",
        separatorBefore: true,
        label: t("chatMenu.transcriptView.makeDefault", { view: t(CHAT_DETAIL_NAMES[level]) }),
        // Nothing to do only when the chat follows the default with no level of its own. A level of
        // its own that equals the default stays clearable here, so later defaults reach the chat.
        disabled: level === defaultChatDetail() && !hasOwnChatDetail(sessionId),
        onSelect: () => makeChatDetailDefault(sessionId, level),
      },
      ...more.map((child, index) => (index ? child : { ...child, separatorBefore: true })),
    ],
  };
}
