import { useSyncExternalStore } from "react";
import { chatDisplay, ownsColumn, type ChatDisplay } from "./chatDisplay";

/// How wide the chat's one column draws on a wide pane (cx-ncc.107, Leo 2026-10-14: "try a wider
/// max width for chat content"). A trial in Debug Settings (`agent.chatWidth`,
/// CmuxNextAgentPane AgentPaneTunables.chatWidth), which the app pushes with the theme
/// (`theme.chatWidth`, AgentPaneTheme.swift) and again when it changes; Leo picks the default
/// from the three before it moves to real Settings.
///
/// - `standard` (the default): the pane's width up to an 800px cap, never under 720px, for everything:
///   the column Settings' Chat Text Width (800 by default) promises, so the default draws the same
///   as any other width the user picks (https://github.com/manaflow-ai/cmux/issues/31510).
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
  standard: { min: 720, max: 800, share: 1, prose: Infinity },
  wide: { min: 720, max: 960, share: 1, prose: Infinity },
  wideBlocks: { min: 720, max: 1120, share: 1, prose: 800 },
};
const isChatWidth = (value: unknown): value is ChatWidth =>
  value === "standard" || value === "wide" || value === "wideBlocks";

/// A pane changed its overlay shift without resizing the transcript. Scoped to its shell.
export const CHAT_LAYOUT_EVENT = "cmux-chat-layout";

let current: ChatWidth = "standard";
const listeners = new Set<() => void>();
export type ChatSizing = { width: ChatWidth; scale: number };
type Snapshot = ChatSizing;

const readUIScale = (): number => {
  if (typeof document === "undefined") return 1;
  const root = document.documentElement;
  const inline = root?.style?.getPropertyValue?.("--cmux-ui-scale") ?? "";
  let computed = "";
  if (!inline && typeof window !== "undefined" && typeof window.getComputedStyle === "function" && root) {
    try {
      computed = window.getComputedStyle(root).getPropertyValue("--cmux-ui-scale");
    } catch {
      // Test DOM shims may expose a document without a usable computed-style implementation.
    }
  }
  const value = Number.parseFloat(inline || computed);
  return Number.isFinite(value) && value > 0 ? value : 1;
};

let currentScale = readUIScale();
let currentSnapshot: Snapshot = { width: current, scale: currentScale };

/// The page publishes its effective page zoom when Interface Scale or Agent Chat Zoom changes.
/// CSS responds to the token directly; this store notification also makes row measurement and
/// gutter decisions use the same scale on the next render.
const refreshUIScale = (): void => {
  const next = readUIScale();
  if (next === currentScale) return;
  currentScale = next;
  currentSnapshot = { width: current, scale: currentScale };
  for (const listener of listeners) listener();
};

if (typeof window !== "undefined") window.addEventListener("cmux-ui-scale-change", refreshUIScale);

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
  currentSnapshot = { width: current, scale: currentScale };
  for (const listener of listeners) listener();
}

/// The column the user's Text Width or Full Width sets (`agentPane.display.*`, chatDisplay.ts),
/// mirroring its `--cv-column`: the pane's whole width up to the cap, at least 720px or the cap.
export const displayColumn = (display: ChatDisplay, scale: number = currentScale): ChatColumn =>
  display.fullWidth
    ? { min: 0, max: Infinity, share: 1, prose: Infinity }
    : {
        min: Math.min(720, display.width) / scale,
        max: display.width / scale,
        share: 1,
        prose: Infinity,
      };
/// A choice's column; the user's own width, when set, wins over the Debug Settings trial.
export const chatColumnOf = (
  chatWidth: ChatWidth,
  display: ChatDisplay = chatDisplay(),
  scale: number = currentScale,
): ChatColumn => {
  if (ownsColumn(display)) return displayColumn(display, scale);
  const column = COLUMNS[chatWidth];
  if (scale === 1) return column;
  return { min: column.min / scale, max: column.max / scale, share: column.share, prose: column.prose / scale };
};
/// The column now.
export const chatColumn = (): ChatColumn => chatColumnOf(current);

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => currentSnapshot;

/// The live choice, so layouts measured at the old column are measured again.
export const useChatWidth = (): ChatWidth => useSyncExternalStore(subscribe, snapshot, snapshot).width;
/// The live choice and the effective page zoom it is sized at, as one subscribed snapshot. Pass
/// `scale` on explicitly: a zero-argument read can be memoized across renders by React Compiler.
export const useChatSizing = (): ChatSizing => useSyncExternalStore(subscribe, snapshot, snapshot);

/// The effective page zoom currently used by chat sizing, for callers that need the same snapshot
/// while deriving a secondary layout measurement.
export const uiScale = (): number => currentScale;
