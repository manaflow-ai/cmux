import { useSyncExternalStore } from "react";
import { chatDisplay, type ChatDisplay } from "./chatDisplay";

/// The chat's one column: Settings > Agents > Chat Layout > Chat Text Width (`agentPane.display.width`,
/// 800 by default) or Chat Full Width (`agentPane.display.fullWidth`), read by chatDisplay.ts. Every
/// chat in every pane draws that width, capped only by the pane
/// (https://github.com/manaflow-ai/cmux/issues/36299). Before, the default 800 left the column to a
/// Debug trial (`agent.chatWidth`): 62.5% of the pane between 720 and 800px, so chats in panes of
/// different widths drew different columns and only a non-default width followed the setting.
///
/// The column is CSS (`--cv-column` in conversation/conversation.css, set by chatDisplay.ts);
/// model.ts transcriptColumn mirrors it here.
export interface ChatColumn {
  /// The column's narrowest width and its cap, in px; between them it takes the pane's width.
  readonly min: number;
  readonly max: number;
}

/// A pane changed its overlay shift without resizing the transcript. Scoped to its shell.
export const CHAT_LAYOUT_EVENT = "cmux-chat-layout";

const listeners = new Set<() => void>();
export type ChatSizing = { scale: number };
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
let currentSnapshot: Snapshot = { scale: currentScale };

/// The page publishes its effective page zoom when Interface Scale or Agent Chat Zoom changes.
/// CSS responds to the token directly; this store notification also makes row measurement and
/// gutter decisions use the same scale on the next render.
const refreshUIScale = (): void => {
  const next = readUIScale();
  if (next === currentScale) return;
  currentScale = next;
  currentSnapshot = { scale: currentScale };
  for (const listener of listeners) listener();
};

if (typeof window !== "undefined") window.addEventListener("cmux-ui-scale-change", refreshUIScale);

/// The column the user's Text Width or Full Width sets (`agentPane.display.*`, chatDisplay.ts),
/// mirroring its `--cv-column`: the pane's whole width up to the cap, at least 720px or the cap.
export const displayColumn = (display: ChatDisplay, scale: number = currentScale): ChatColumn =>
  display.fullWidth
    ? { min: 0, max: Infinity }
    : { min: Math.min(720, display.width) / scale, max: display.width / scale };
/// The column `display` sets, at the page zoom `scale`.
export const chatColumnOf = (display: ChatDisplay = chatDisplay(), scale: number = currentScale): ChatColumn =>
  displayColumn(display, scale);
/// The column now.
export const chatColumn = (): ChatColumn => chatColumnOf();

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => currentSnapshot;

/// The effective page zoom the column is sized at, as a subscribed snapshot. Pass
/// `scale` on explicitly: a zero-argument read can be memoized across renders by React Compiler.
export const useChatSizing = (): ChatSizing => useSyncExternalStore(subscribe, snapshot, snapshot);

/// The effective page zoom currently used by chat sizing, for callers that need the same snapshot
/// while deriving a secondary layout measurement.
export const uiScale = (): number => currentScale;
