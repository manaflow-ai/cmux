import { useSyncExternalStore } from "react";

/// How wide the chat's one column draws on a wide pane (cx-ncc.107, Leo 2026-10-14: "try a wider
/// max width for chat content"). A trial, not a setting yet: the person picks it in
/// `agent-pane/layout.json` next to `cmux.json` (the file the App watches and pushes through
/// `applyCustomization`), and Leo picks the default from the three.
///
///     {"chatWidth": "wide"}
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

/// `layout.chatWidth`, or `standard` when it is missing or unknown.
export function readChatWidth(layout: Record<string, unknown> | undefined): ChatWidth {
  const value = layout?.chatWidth;
  return isChatWidth(value) ? value : "standard";
}

/// The host pushed `layout.json` (or `{}` when it was removed): the column follows at once.
export function configureChatWidth(layout: Record<string, unknown> | undefined): void {
  const next = readChatWidth(layout);
  if (next === current) return;
  current = next;
  if (typeof document !== "undefined") {
    if (next === "standard") delete document.documentElement.dataset.chatWidth;
    else document.documentElement.dataset.chatWidth = next;
  }
  for (const listener of listeners) listener();
}

/// A choice's column.
export const chatColumnOf = (chatWidth: ChatWidth): ChatColumn => COLUMNS[chatWidth];
/// The column now.
export const chatColumn = (): ChatColumn => COLUMNS[current];

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// The live choice, so layouts measured at the old column are measured again.
export const useChatWidth = (): ChatWidth => useSyncExternalStore(subscribe, snapshot, snapshot);
