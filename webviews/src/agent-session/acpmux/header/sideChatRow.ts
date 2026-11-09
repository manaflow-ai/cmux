// The chat menu's New side chat row: forks the chat through its last turn into a new session
// that the app opens in a split beside the chat (`chat.side`), leaving the chat where it is.
import { forkRefusal, latestForkSeq } from "../conversation/messageMenu";
import { type Translate, translate } from "../i18n";
import type { AcpmuxSnapshot } from "../model";
import type { ChatMenuItem } from "./chatHeaderToolsModel";

/// Where New side chat and `/side` fork the chat: `local`, this Mac's acpmux (the chat's folder
/// is on this Mac); `machine`, the chat's own machine (a Cloud or SSH chat whose machine opens side
/// chats, `sideChatOnMachine`): the side chat runs there, in the chat's folder on that machine, and
/// opens beside the chat as a local one does ("whatever works on a local chat should work on a
/// Cloud chat", cmuxterm-hq#7856). Undefined: nowhere. Quick Chat's panel has no split beside it.
export type SideChatPlace = "local" | "machine";

export function sideChatPlace(chat: {
  quick: boolean;
  localCwd: string | undefined;
  onMachine: boolean | undefined;
}): SideChatPlace | undefined {
  if (chat.quick) return undefined;
  if (chat.localCwd !== undefined) return "local";
  return chat.onMachine ? "machine" : undefined;
}

/// Why a side chat cannot fork the chat now in `place`, as `forkRefusal` words it: a working chat
/// forks as it is now (#38042); one with no finished turn has nothing to copy yet.
export function sideChatRefusal(
  snapshot: AcpmuxSnapshot,
  place: SideChatPlace | undefined,
): "unavailable" | "nothingYet" | undefined {
  if (place === "local") return forkRefusal(snapshot);
  const connected = snapshot.connection !== "disconnected" && !snapshot.connection.startsWith("connecting");
  if (place !== "machine" || !connected) return "unavailable";
  if (!snapshot.isWorking && latestForkSeq(snapshot.rows) === undefined) return "nothingYet";
  return undefined;
}

export function sideChatRow(
  chat: { canFork: boolean; throughSeq: number | undefined; place: SideChatPlace | undefined },
  open: (throughSeq: number) => void,
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator"> | undefined {
  const { throughSeq } = chat;
  // A fork needs a turn to copy, and a place that opens it beside the chat.
  if (!chat.canFork || throughSeq === undefined || chat.place === undefined) return undefined;
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
