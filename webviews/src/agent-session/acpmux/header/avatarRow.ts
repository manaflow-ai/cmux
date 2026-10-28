// The chat menu's Set Avatar… and Remove Avatar (Leo 2026-10-26: "upload their own"): the person's
// own picture for this agent session, which its cards and sender chip draw (agentAvatar.ts).
import { type Translate, translate } from "../i18n";
import type { ChatMenuItem } from "./ChatHeaderTools";

export function avatarRows(
  chat: { sessionId: string | undefined; hasAvatar: boolean },
  actions: { set: () => void; remove: () => void },
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator">[] {
  if (!chat.sessionId) return [];
  const set = { key: "setAvatar", label: t("chatMenu.setAvatar"), icon: "account", onSelect: actions.set };
  if (!chat.hasAvatar) return [set];
  return [set, { key: "removeAvatar", label: t("chatMenu.removeAvatar"), icon: "account", onSelect: actions.remove }];
}
