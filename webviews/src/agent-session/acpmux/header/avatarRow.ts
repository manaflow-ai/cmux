// The chat menu's Set Chat Avatar… and Remove Chat Avatar (Leo 2026-10-26: "upload their own"): the
// person's own picture for this agent session, which its cards and sender chip draw (agentAvatar.ts).
// "Chat" in the label says whose avatar it is, not the Chief's or the person's (Leo 2026-11-07: "What
// is an avatar supposed to be?"), and the rows draw the chat's picture once it has one.
import { type Translate, translate } from "../i18n";
import type { ChatMenuItem } from "./chatHeaderToolsModel";

export function avatarRows(
  chat: { sessionId: string | undefined; avatar: string | undefined },
  actions: { set: () => void; remove: () => void },
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator">[] {
  if (!chat.sessionId) return [];
  const image = chat.avatar ? { image: chat.avatar } : {};
  const set = { key: "setAvatar", label: t("chatMenu.setAvatar"), icon: "account", ...image, onSelect: actions.set };
  if (!chat.avatar) return [set];
  return [set, { key: "removeAvatar", label: t("chatMenu.removeAvatar"), icon: "account", onSelect: actions.remove }];
}
