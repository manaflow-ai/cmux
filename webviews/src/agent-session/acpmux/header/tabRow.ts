import { useCallback, useEffect, useRef, useSyncExternalStore, type CSSProperties } from "react";
import { setPopupInsetTop } from "../../../ui/popupInset";

/// The pane's tab row the chat header's tools may sit in (CmuxNextAgentPane AgentPaneTabRow, the
/// `chrome.tabs.rowTools` Debug setting; Leo 2026-10-14, "why is there even a top bar"). The App
/// offers it with the `tabRow` event only while that setting is on and the chat's pane shows its
/// tabs on top: `height` is the row's, `trailingInset` the width the pane's own "…" keeps at its
/// right end, both in CSS pixels. Height 0 (the default) is the header's own row, as before.
export interface TabRow {
  readonly height: number;
  readonly trailingInset: number;
  /// Debug chrome.tabs.nativeRowTools; absent/false keeps the existing web buttons.
  readonly nativeRowTools?: boolean;
}

/// Space between the last tab and the tools, in the width the page reports: the tools' own pitch, not a gutter.
export const TAB_ROW_GAP = 4;

const NONE: TabRow = { height: 0, trailingInset: 0 };
let current: TabRow = NONE;
const listeners = new Set<() => void>();

const pixels = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0);

/// The App's `tabRow` push; anything without a positive height ends the one-row header. Each
/// offered row is a new one, even when it equals the last: the App offers it again after it forgot
/// the tools' width (the page said ready again), and the page reports the width again for it.
export function setTabRow(value: unknown): void {
  const raw = (value ?? {}) as { height?: unknown; trailingInset?: unknown; nativeRowTools?: unknown };
  const height = pixels(raw.height);
  current =
    height > 0
      ? { height, trailingInset: pixels(raw.trailingInset), nativeRowTools: raw.nativeRowTools === true }
      : NONE;
  // The native row draws over the page's top, so menus and popovers open below it (ui/popupInset.ts).
  setPopupInsetTop(current.height);
  for (const listener of listeners) listener();
}

const tabRow = (): TabRow => current;
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// The row the App offers now.
export const useTabRow = (): TabRow => useSyncExternalStore(subscribe, tabRow, tabRow);

/// The header's height and right inset in the row, for the stage that holds the header and the
/// summary card (header.css, summary.css); none outside it.
export function tabRowStyle(row: TabRow): CSSProperties | undefined {
  if (row.height <= 0) return undefined;
  return {
    "--acpmux-tab-row-height": `${row.height}px`,
    "--acpmux-tab-row-inset": `${row.trailingInset}px`,
  } as CSSProperties;
}

/// While in an offered `row`, reports the width of the tools the returned ref names (plus ``TAB_ROW_GAP``) each
/// time it changes or the row is offered again, so the App narrows the tabs by that much; reports 0 once it ends or the tools
/// leave (a New Tab page, a replay), so the tabs take the row back. `report` should be stable. The
/// ref keeps the element without state: a render it caused on mount raced the chat's first
/// snapshot (a relaunched new chat lost its kept draft).
export function useTabRowTools(
  row: TabRow | undefined,
  report: (width: number) => void,
): (element: HTMLElement | null) => void {
  const tools = useRef<HTMLElement | null>(null);
  const stop = useRef<(() => void) | undefined>(undefined);
  const follow = useCallback(() => {
    stop.current?.();
    stop.current = undefined;
    const element = tools.current;
    if (!row || !element || typeof ResizeObserver === "undefined") return;
    let last = 0;
    const measure = () => {
      const box = Math.round(element.getBoundingClientRect().width);
      const width = box > 0 ? box + TAB_ROW_GAP : 0;
      if (width === last) return;
      last = width;
      report(width);
    };
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    measure();
    stop.current = () => {
      observer.disconnect();
      if (last > 0) report(0);
    };
  }, [row, report]);
  useEffect(() => {
    follow();
    return () => {
      stop.current?.();
      stop.current = undefined;
    };
  }, [follow]);
  return useCallback(
    (element: HTMLElement | null) => {
      if (tools.current === element) return;
      tools.current = element;
      follow();
    },
    [follow],
  );
}
