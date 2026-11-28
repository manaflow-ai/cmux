// The chat menu's New side chat row: forks the chat through its last turn into a new session
// that the app opens in a split beside the chat (`chat.side`), leaving the chat where it is.
import { type Translate, translate } from "../i18n";
import type { ChatMenuItem } from "./ChatHeaderTools";

export function sideChatRow(
  chat: { canFork: boolean; throughSeq: number | undefined; local: boolean },
  open: (throughSeq: number) => void,
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator"> | undefined {
  const { throughSeq } = chat;
  // A fork needs a turn to copy, and the split opens this Mac's session.
  if (!chat.canFork || throughSeq === undefined || !chat.local) return undefined;
  return { key: "sideChat", label: t("chatMenu.sideChat"), icon: "agent.chat.new", onSelect: () => open(throughSeq) };
}
