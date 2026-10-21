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

/// The chat menu's group of rows that open something new beside the chat: New side chat, New
/// terminal and New browser, a new one on every click. Quick Chat's panel is not a tab: there is
/// no split to open beside it, so it has none of them.
export function opensBesideRows(
  chat: { sideChat: Exclude<ChatMenuItem, "separator"> | undefined; quick: boolean },
  open: { terminal: () => void; browser: () => void },
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator">[] {
  if (chat.quick) return [];
  return [
    ...(chat.sideChat ? [chat.sideChat] : []),
    { key: "newTerminal", label: t("chatMenu.newTerminal"), icon: "terminal", onSelect: open.terminal },
    { key: "newBrowser", label: t("chatMenu.newBrowser"), icon: "browser", onSelect: open.browser },
  ];
}
