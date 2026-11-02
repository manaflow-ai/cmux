// What the chat was granted (the folder's trust, a chat-wide allowance), and the chat menu's
// Revoke Granted Access row that takes each back. The composer's mode menu lists the modes alone
// (Leo, 2026-10-29: "What is this bottom fucking bullshit?"), so a grant needs a home that is
// always there: the chat menu (…) is in every chat with default settings, where Session Info's
// Environment (session-info/EnvironmentSection.tsx) shows only with Debug Settings `agent.inspector`
// on. Once trust is decided the trust bar is gone, so without this row a trusted folder had no
// visible way back with default settings.
import { type Translate, translate } from "../i18n";
import type { AccessGrant } from "../session-info/EnvironmentSection";
import type { ChatMenuItem } from "./ChatHeaderTools";

export type GrantSources = {
  /// The chat's folder is trusted (decided, not asked): `useFolderTrustAsk().trusted`.
  trusted: boolean;
  /// Where the trust lives, as the grant names it ("Trusted cmux"); the private folder's name when absent.
  trustLabel?: string;
  /// Forgets the trust (`useFolderTrustAsk().undo`).
  untrust: () => void;
  /// The chat holds a chat-wide allowance (`permissionGroups.chatAllowance`).
  chatAllowance: boolean;
  /// The allowance comes from the chat's last read and its refresh has not landed: not yet removable.
  allowanceUnread: boolean;
  /// Revokes the allowance (`chat.permission_chat.revoke`).
  revokeAllowance: () => void;
};

/// The chat's grants, each with how to take it back: Session Info's Environment rows and the chat
/// menu's Revoke Granted Access submenu read the same list.
export function chatAccessGrants(sources: GrantSources, t: Translate = translate): AccessGrant[] {
  return [
    ...(sources.trusted
      ? [{ id: "folder-trust", label: sources.trustLabel ?? t("trust.trustedPrivate"), onRemove: sources.untrust }]
      : []),
    ...(sources.chatAllowance
      ? [
          {
            id: "chat-permission",
            label: t("permission.allowChat"),
            onRemove: () => (sources.allowanceUnread ? undefined : sources.revokeAllowance()),
          },
        ]
      : []),
  ];
}

/// The chat menu's Revoke Granted Access: a submenu naming each grant, whose pick revokes it (the
/// second, deliberate click is the confirmation). No row when nothing is granted.
export function revokeAccessRows(
  grants: readonly AccessGrant[],
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator">[] {
  if (grants.length === 0) return [];
  return [
    {
      key: "revokeAccess",
      label: t("chatMenu.revokeAccess"),
      icon: "security.lock",
      children: grants.map((grant) => ({ key: grant.id, label: grant.label, onSelect: grant.onRemove })),
    },
  ];
}
