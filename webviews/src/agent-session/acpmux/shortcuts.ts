import { createContext, useContext } from "react";

/// The app actions whose shortcuts the page shows. The host binds them (Settings, cmux.json) and
/// pushes their keycaps through the bridge's applyShortcuts (CmuxNextAgentPane AgentPaneShortcuts).
export const SHORTCUT_ACTIONS = {
  searchChats: "agentPane.searchChats",
  newAgentChat: "palette.newAgentChat",
  toggleDictation: "palette.toggleDictation",
  permissionAllowOnce: "agentPane.permission.allowOnce",
  permissionAllowChat: "agentPane.permission.allowChat",
  permissionDeny: "agentPane.permission.deny",
  permissionRetry: "agentPane.permission.retry",
  permissionRevoke: "agentPane.permission.revoke",
  permissionRefresh: "agentPane.permission.refresh",
  permissionExpand: "agentPane.permission.expand",
} as const;

/// Keycaps by action id, such as `{"agentPane.searchChats": "⌘K"}`. An action without a
/// shortcut is absent, so the page shows none rather than a stale default.
export type ShortcutLabels = Readonly<Record<string, string>>;

/// The host's payload as labels, keeping only non-empty string keycaps.
export function readShortcuts(value: unknown): ShortcutLabels {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(
    Object.entries(value).filter((entry): entry is [string, string] => typeof entry[1] === "string" && entry[1] !== ""),
  );
}

/// A tooltip naming its shortcut, "Search chats (⌘K)", or the plain label without one.
export const withShortcut = (label: string, shortcut: string | undefined) =>
  shortcut ? `${label} (${shortcut})` : label;

export const ShortcutsContext = createContext<ShortcutLabels>({});

/// The live keycaps for `action`, or undefined while it has no shortcut.
export const useShortcut = (action: string): string | undefined => useContext(ShortcutsContext)[action];
