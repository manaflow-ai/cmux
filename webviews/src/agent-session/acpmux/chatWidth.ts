import { useSyncExternalStore } from "react";
import { chatDisplay, ownsColumn, type ChatDisplay } from "./chatDisplay";

/// How wide the chat's one column draws on a wide pane (cx-ncc.107, Leo 2026-10-14: "try a wider
/// max width for chat content"). A trial in Debug Settings (`agent.chatWidth`,
/// CmuxNextAgentPane AgentPaneTunables.chatWidth), which the app pushes with the theme
/// (`theme.chatWidth`, AgentPaneTheme.swift) and again when it changes; Leo picks the default
/// from the three before it moves to real Settings.
///
/// - `standard` (the default): 720px, widening with the pane to an 800px cap, for everything.
/// - `wide`: the same, to a 960px cap, for everything.
/// - `wideBlocks`: a 1120px cap for code, diffs, tables, tool output and cards, while prose keeps
///   the standard 800px measure at the column's left edge, so reading lines stay as long as today.
///
/// The column is CSS (`--cv-column` and `--cv-prose` in conversation/conversation.css, chosen by
/// `data-chat-width` on the root); model.ts transcriptColumn and the prose measure mirror it here.
export type ChatWidth = "standard" | "wide" | "wideBlocks";

export interface ChatColumn {
  /// The column's narrowest width and its cap, in px, and its share of a wider pane.
  readonly min: number;
  readonly max: number;
  readonly share: number;
  /// The widest prose line, in px; Infinity when prose takes the whole column.
  readonly prose: number;
}

const COLUMNS: Record<ChatWidth, ChatColumn> = {
  standard: { min: 720, max: 800, share: 0.625, prose: Infinity },
  wide: { min: 720, max: 960, share: 0.625, prose: Infinity },
  wideBlocks: { min: 720, max: 1120, share: 0.7, prose: 800 },
};
const isChatWidth = (value: unknown): value is ChatWidth =>
  value === "standard" || value === "wide" || value === "wideBlocks";

let current: ChatWidth = "standard";
const listeners = new Set<() => void>();

/// The theme's `chatWidth`, or `standard` when it is missing or unknown.
export const readChatWidth = (value: unknown): ChatWidth => (isChatWidth(value) ? value : "standard");

/// The host pushed the theme: the column follows at once.
export function configureChatWidth(value: unknown): void {
  const next = readChatWidth(value);
  if (next === current) return;
  current = next;
  if (typeof document !== "undefined") {
    if (next === "standard") delete document.documentElement.dataset.chatWidth;
    else document.documentElement.dataset.chatWidth = next;
  }
  for (const listener of listeners) listener();
}

/// The column the user's Text Width or Full Width sets (`agentPane.display.*`, chatDisplay.ts),
/// mirroring its `--cv-column`: the pane's whole width up to the cap, at least 720px or the cap.
export const displayColumn = (display: ChatDisplay): ChatColumn =>
  display.fullWidth
    ? { min: 0, max: Infinity, share: 1, prose: Infinity }
    : { min: Math.min(720, display.width), max: display.width, share: 1, prose: Infinity };
/// A choice's column; the user's own width, when set, wins over the Debug Settings trial.
export const chatColumnOf = (chatWidth: ChatWidth, display: ChatDisplay = chatDisplay()): ChatColumn =>
  ownsColumn(display) ? displayColumn(display) : COLUMNS[chatWidth];
/// The column now.
export const chatColumn = (): ChatColumn => chatColumnOf(current);

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// The live choice, so layouts measured at the old column are measured again.
export const useChatWidth = (): ChatWidth => useSyncExternalStore(subscribe, snapshot, snapshot);
