// The summary card's place (summary/SummaryCard.tsx): shown or not, and folded to its header or
// open. The panel visibility preference is shared by the current pane so a responsive resize does
// not unexpectedly reopen it.
//
// A chat with summary content shows the inline card when there is room; an empty chat stays quiet
// until the user explicitly opens the summary button. Any hide choice is stored for this pane.
import { useCallback, useLayoutEffect, useState, useSyncExternalStore } from "react";
import { chatColumnOf, uiScale, useChatSizing, type ChatColumn } from "../chatWidth";
import { useChatDisplay } from "../chatDisplay";
import { transcriptColumn } from "../model";

/// The inline summary column is only useful when the chat keeps a readable width beside it.
export const SUMMARY_COLUMN_WIDTH = 300;
const CHAT_MIN_WIDTH = 660;

/// The chat's width beside the inline summary: its whole Chat Text Width column with the page edge on
/// each side (model.ts transcriptColumn), and never less than a readable 660px; with Chat Full Width,
/// the readable floor alone. Both follow the effective page scale as the column's cap does. A caller
/// can pass a column and scale explicitly for geometry tests; the live summary uses the page's.
export const inlineChatFloor = (column: ChatColumn = chatColumnOf(), scale: number = uiScale()) =>
  Number.isFinite(column.max)
    ? Math.max(CHAT_MIN_WIDTH / scale, column.max + 2 * transcriptColumn(0, column).inset)
    : CHAT_MIN_WIDTH / scale;

const PANEL_KEY = "cmux.acpmux.summaryPanel";
let panelHidden: boolean | undefined;
const panelListeners = new Set<() => void>();

function readPanelHidden() {
  if (panelHidden !== undefined) return panelHidden;
  try {
    panelHidden = globalThis.localStorage?.getItem(PANEL_KEY) === "hidden";
  } catch {
    panelHidden = false;
  }
  return panelHidden;
}

function setPanelHidden(hidden: boolean) {
  panelHidden = hidden;
  try {
    if (hidden) globalThis.localStorage?.setItem(PANEL_KEY, "hidden");
    else globalThis.localStorage?.removeItem(PANEL_KEY);
  } catch {
    // Storage may be absent (tests, private windows): keep the in-page choice.
  }
  for (const listener of panelListeners) listener();
}

/// Forgets every chat's choice: the gallery mounts each variant on a clean slate, as all its chats
/// share one session id.
export function resetSummaryCards() {
  try {
    globalThis.localStorage?.removeItem(PANEL_KEY);
  } catch {
    // Nothing stored.
  }
  setPanelHidden(false);
}

const subscribePanel = (listener: () => void) => {
  panelListeners.add(listener);
  const storage = (event: StorageEvent) => {
    if (event.key !== PANEL_KEY && event.key !== null) return;
    panelHidden = undefined;
    listener();
  };
  globalThis.addEventListener?.("storage", storage);
  return () => {
    panelListeners.delete(listener);
    globalThis.removeEventListener?.("storage", storage);
  };
};

/** Whether the pane can keep a readable chat column beside the inline summary. */
export function useSummaryColumn(shell: HTMLElement | null, blocked: boolean): boolean {
  const [room, setRoom] = useState(false);
  const { scale } = useChatSizing();
  const display = useChatDisplay();
  useLayoutEffect(() => {
    if (!shell || blocked) {
      setRoom(false);
      return;
    }
    const measure = () => {
      const rail = shell.querySelector<HTMLElement>(":scope>.acpmux-session-info");
      const reserved = rail?.offsetWidth ?? 0;
      const available = shell.clientWidth - reserved;
      // The summary takes 300px from the same flex row as the transcript. Where that would narrow
      // the chat's column below its Chat Text Width, keep it as a popover.
      setRoom(available >= inlineChatFloor(chatColumnOf(display, scale), scale) + SUMMARY_COLUMN_WIDTH);
    };
    measure();
    const frame = requestAnimationFrame(measure);
    const observer = new ResizeObserver(measure);
    observer.observe(shell);
    const rail = shell.querySelector<HTMLElement>(":scope>.acpmux-session-info");
    if (rail) observer.observe(rail);
    const children = new MutationObserver(measure);
    children.observe(shell, { childList: true });
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
      children.disconnect();
    };
  }, [shell, blocked, display, scale]);
  return room;
}

/** Summary state for a pane with room for an inline column or a narrow popover. */
export function useSummaryCard(column: boolean, hasContent: boolean) {
  const hidden = useSyncExternalStore(subscribePanel, readPanelHidden, () => false);
  const [popover, setPopover] = useState(false);
  const [explicit, setExplicit] = useState(false);
  const [collapsed, setCollapsed] = useState(false);
  const shown = column ? !hidden && (hasContent || explicit) : popover;
  const reserve = column && !hidden && !hasContent && !explicit;
  const show = useCallback(() => {
    setCollapsed(false);
    if (column) {
      setExplicit(true);
      setPanelHidden(false);
    } else setPopover(true);
  }, [column]);
  const close = useCallback(() => {
    if (column) {
      setExplicit(false);
      setPanelHidden(true);
    } else setPopover(false);
  }, [column]);
  const toggle = useCallback(() => (shown ? close() : show()), [shown, close, show]);
  const fold = useCallback((next: boolean) => setCollapsed(next), []);
  return { shown, column, reserve, collapsed, toggle, show, close, fold };
}

export type SummaryCardControl = ReturnType<typeof useSummaryCard>;
