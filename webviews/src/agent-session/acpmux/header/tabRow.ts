import { useCallback, useEffect, useLayoutEffect, useRef, useSyncExternalStore, type CSSProperties } from "react";
import { setPopupInsetTop } from "../../../ui/popupInset";

/// The pane's tab row the chat header's tools may sit in (CmuxNextAgentPane AgentPaneTabRow; Leo
/// 2026-10-14, "why is there even a top bar"). The App offers it with the `tabRow` event only while
/// the chat's pane shows its tabs on top: `height` is the row's, `trailingInset` the width the pane's own "…" keeps at its
/// right end, both in CSS pixels. Height 0 (the default) is the header's own row, as before.
export interface TabRow {
  readonly height: number;
  readonly trailingInset: number;
  /// Debug chrome.tabs.nativeRowTools; absent/false keeps the existing web buttons.
  readonly nativeRowTools?: boolean;
  /// The pane holds this one tab (PaneContentView): the row has no band of its own. The transcript runs up
  /// to the pane's top under it, its tab and tools floating over the chat (Leo, 2026-11-03: "what if we could
  /// ... have even more of that area be not some row blocking it? cuz isn't it kinda arbitrary anyway if you
  /// literally only have one tab there?"). Absent/false: two or more tabs, the row as before.
  readonly soloTab?: boolean;
  /// The most the row's accessories (``TAB_ROW_ACCESSORY``) may take, CSS pixels: the room the pane's tabs leave at
  /// their full width, past the tools (PaneContentView, TabRowAccessoryFit; #53314: the tabs fill the row first, the
  /// summary only gets what is left). Absent: no limit beyond the half of the row.
  readonly accessoryRoom?: number;
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
  const raw = (value ?? {}) as {
    height?: unknown;
    trailingInset?: unknown;
    nativeRowTools?: unknown;
    soloTab?: unknown;
    accessoryRoom?: unknown;
  };
  const accessoryRoom =
    typeof raw.accessoryRoom === "number" && Number.isFinite(raw.accessoryRoom)
      ? Math.max(0, raw.accessoryRoom)
      : undefined;
  const height = pixels(raw.height);
  current =
    height > 0
      ? {
          height,
          trailingInset: pixels(raw.trailingInset),
          nativeRowTools: raw.nativeRowTools === true,
          soloTab: raw.soloTab === true,
          ...(accessoryRoom === undefined ? {} : { accessoryRoom }),
        }
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

/// The top of a viewer over the whole pane (the image viewer, the video player, the chat's gallery): it is portaled
/// outside the shell that carries the row's height, and the row draws over the page's top, so it starts below the row
/// and its name never sits under the tabs (Leo, 2026-11-05: "the file nameis also way at the top"). None outside it.
export function belowTabRowStyle(row: TabRow): CSSProperties | undefined {
  if (row.height <= 0) return undefined;
  return { "--acpmux-image-viewer-top": `${row.height}px` } as CSSProperties;
}

/// The document root's mark that a chat shell sits in the tab row (header.css, src/styles.css: the page's own
/// background stays clear in the row). An attribute the shell sets, not `html:has(.acpmux-shell[data-tab-row])`:
/// a `:has()` on the root is checked again for every node a streamed chunk inserts into the transcript, and
/// each check restyles the composer (test/agent-pane-stream-composer-still.test.ts).
export const TAB_ROW_ROOT_ATTRIBUTE = "data-acpmux-tab-row";
const tabRowShells = new WeakMap<Document, number>();

/// Marks `shell`'s document root while `shell` is mounted in the tab row; the mark leaves with the last such shell.
export function useTabRowRoot(shell: HTMLElement | null, inTabRow: boolean): void {
  useLayoutEffect(() => {
    if (!shell || !inTabRow) return;
    const document = shell.ownerDocument;
    tabRowShells.set(document, (tabRowShells.get(document) ?? 0) + 1);
    document.documentElement.setAttribute(TAB_ROW_ROOT_ATTRIBUTE, "");
    return () => {
      const left = (tabRowShells.get(document) ?? 1) - 1;
      tabRowShells.set(document, left);
      if (left === 0) document.documentElement.removeAttribute(TAB_ROW_ROOT_ATTRIBUTE);
    };
  }, [shell, inTabRow]);
}

/// A tools child that takes only the row's leftover room (none today; the chat's rolling summary was one until 11-24): it is in
/// the width the tools report while it shows, so the tabs give it up, but never in their need, which decides whether
/// the pane offers the row at all (PaneTabRowSharing.fitsTabRow). Before, the summary was in the need: a pane split
/// narrower than the width it was measured at stopped offering the row, and the chat's tools dropped to a second row
/// under the tabs, in a narrow pane the tools slid under the last tab (Leo, 2026-11-22: "the icons on the top right
/// have gotten displaced due to putting things on a line").
export const TAB_ROW_ACCESSORY = "data-tab-row-accessory";
/// Narrower than this an accessory says nothing worth its place, and the row hides it whole rather than cut it to a
/// few letters.
export const TAB_ROW_ACCESSORY_MIN = 160;

/// What the tools take of a row: `width` all of it, `need` without accessories, `room` the most the accessories may
/// take (the half of the row the strip gives up, less the need, and at most `limit`: what the tabs leave free,
/// ``TabRow.accessoryRoom``), 0 when that is under ``TAB_ROW_ACCESSORY_MIN``.
export function tabRowToolsFit(
  box: number,
  accessories: number,
  rowWidth: number,
  limit = Number.POSITIVE_INFINITY,
): { width: number; need: number; room: number } {
  const width = box > 0 ? box + TAB_ROW_GAP : 0;
  const need = width > 0 ? Math.max(0, width - accessories) : 0;
  const room = Math.max(0, Math.floor(Math.min(rowWidth / 2 - need, limit)));
  return { width, need, room: room >= TAB_ROW_ACCESSORY_MIN ? room : 0 };
}

/// While in an offered `row`, reports the width of the tools the returned ref names (plus ``TAB_ROW_GAP``) and their
/// need (that width less ``TAB_ROW_ACCESSORY`` children) each time either changes or the row is offered again, so the
/// App narrows the tabs by the width and offers the row by the need; reports 0 once it ends or the tools leave (a New
/// Tab page, a replay). It also gives the accessories their room, `--acpmux-tab-row-accessory-room` on the tools and
/// `data-tab-row-accessories="hidden"` when there is none, so the tools never take more than the half of the row the
/// strip gives up: the row is the tools' parent, less its padding (the pane's own "…").
/// A row offered anew (another inset: a tab opened, closed or selected changed the
/// pane's toolbar) reports the width again with no 0 between: the 0 had the App lay the chat under its tabs for a moment,
/// its tools in a second row (Leo 2026-11-07: "the top right button area is somehow, like, shifting its layout").
/// `report` should be stable. The ref keeps the element without state: a render it caused on mount raced the chat's
/// first snapshot (a relaunched new chat lost its kept draft).
export function useTabRowTools(
  row: TabRow | undefined,
  report: (width: number, need: number) => void,
): (element: HTMLElement | null) => void {
  const tools = useRef<HTMLElement | null>(null);
  const stop = useRef<(() => void) | undefined>(undefined);
  /// The width and need last reported, across rows: 0 goes out only when the tools leave the row.
  const reported = useRef(0);
  const reportedNeed = useRef(0);
  const reportedRow = useRef<TabRow | undefined>(undefined);
  const follow = useCallback(() => {
    stop.current?.();
    stop.current = undefined;
    const element = tools.current;
    if (element) {
      element.style.removeProperty("--acpmux-tab-row-accessory-room");
      element.removeAttribute("data-tab-row-accessories");
    }
    if (!row || !element || typeof ResizeObserver === "undefined") {
      reportedRow.current = undefined;
      if (reported.current > 0) {
        reported.current = 0;
        reportedNeed.current = 0;
        report(0, 0);
      }
      return;
    }
    const rowElement = element.parentElement;
    // Each offered row is a new one: its first measure reports even an unchanged width (the App may have forgotten it),
    // once per row however often the element is followed.
    const measure = () => {
      const box = Math.round(element.getBoundingClientRect().width);
      const styleOf = (node: Element) => node.ownerDocument.defaultView?.getComputedStyle(node);
      let accessories = 0;
      const gap = parseFloat(styleOf(element)?.columnGap ?? "") || 0;
      for (const child of element.querySelectorAll<HTMLElement>(`[${TAB_ROW_ACCESSORY}]`)) {
        const width = child.getBoundingClientRect().width;
        if (width > 0) accessories += width + gap;
      }
      let rowWidth = 0;
      if (rowElement) {
        const style = styleOf(rowElement);
        rowWidth =
          rowElement.clientWidth -
          (parseFloat(style?.paddingLeft ?? "") || 0) -
          (parseFloat(style?.paddingRight ?? "") || 0);
      }
      // The App's room is for an accessory and its gap, as they count in the width.
      const limit = row.accessoryRoom === undefined ? Number.POSITIVE_INFINITY : row.accessoryRoom - gap;
      const fit = tabRowToolsFit(box, Math.round(accessories), rowWidth, limit);
      element.style.setProperty("--acpmux-tab-row-accessory-room", `${fit.room}px`);
      if (fit.room > 0) element.removeAttribute("data-tab-row-accessories");
      else element.setAttribute("data-tab-row-accessories", "hidden");
      if (fit.width === reported.current && fit.need === reportedNeed.current && reportedRow.current === row) return;
      reportedRow.current = row;
      reported.current = fit.width;
      reportedNeed.current = fit.need;
      report(fit.width, fit.need);
    };
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    if (rowElement) observer.observe(rowElement);
    measure();
    stop.current = () => observer.disconnect();
  }, [row, report]);
  useEffect(() => {
    follow();
    return () => {
      stop.current?.();
      stop.current = undefined;
    };
  }, [follow]);
  // Unmounted: the tools left the row.
  useEffect(
    () => () => {
      if (reported.current > 0) report(0, 0);
      reported.current = 0;
      reportedNeed.current = 0;
    },
    [report],
  );
  // One ref callback for the hook's life: a new one per row had React detach the old with null first, and that
  // reported 0 before the new one reported the width again.
  const latest = useRef(follow);
  latest.current = follow;
  return useCallback((element: HTMLElement | null) => {
    if (tools.current === element) return;
    tools.current = element;
    latest.current();
  }, []);
}
