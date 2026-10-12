// A menu with no room in the page goes past the window's edge (cx-6k6cg), as a Mac menu does. Base
// UI flips a menu to the side that fits; when neither side of its anchor has room for every row,
// the page hands the rows to the native host (WebPopupHost), which draws them in a child panel on
// the screen. The page's own menu stays mounted, invisible: focus, the arrows, typeahead and
// accessibility stay Base UI's. Its highlight and rows follow to the host as they change; a click
// there comes back as a click on the page's row. Pages without a host (Settings) never escape:
// their menus fit and scroll in the page.
import { useEffect, useRef } from "react";

export interface PopupItem {
  id: string;
  label: string;
  shortcut?: string;
  checked?: boolean;
  disabled?: boolean;
  separator?: boolean;
}

export interface PopupModel {
  items: PopupItem[];
  highlighted: string | null;
  /** The anchor, in CSS px in the page's viewport. */
  anchor: { left: number; top: number; right: number; bottom: number };
  side: "bottom" | "top";
  align: "start" | "end";
  width: number;
}

export type PopupEvent = { type: "pick"; id: string } | { type: "highlight"; id: string } | { type: "dismiss" };

export interface PopupHost {
  show(model: PopupModel): Promise<unknown>;
  update(model: PopupModel): void;
  hide(): void;
  listen(listener: (event: PopupEvent) => void): () => void;
}

/** A host over a native call (`popup.show/update/hide`) and the window event `cmux-popup`. */
export function nativePopupHost(
  post: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): PopupHost {
  const quiet = (method: string, params: Record<string, unknown> = {}) => post(method, params).catch(() => undefined);
  return {
    show: (model) => quiet("popup.show", { ...model }),
    update: (model) => void quiet("popup.update", { ...model }),
    hide: () => void quiet("popup.hide"),
    listen(listener) {
      const receive = (event: Event) => listener((event as CustomEvent<PopupEvent>).detail);
      window.addEventListener("cmux-popup", receive);
      return () => window.removeEventListener("cmux-popup", receive);
    },
  };
}

const ROWS = '[role="menuitem"],[role="menuitemradio"],[role="menuitemcheckbox"],[role="option"],[role="separator"]';
/** Room kept from the page's edge, as Base UI's collision padding. */
const EDGE = 5;

/** The menu's rows as the host draws them: each row's text without its check or shortcut. */
export function popupItems(popup: Element): { items: PopupItem[]; rows: Element[]; highlighted: string | null } {
  const rows = [...popup.querySelectorAll(ROWS)];
  let highlighted: string | null = null;
  const items = rows.map((row, index): PopupItem => {
    const id = String(index);
    if (row.getAttribute("role") === "separator") return { id, label: "", separator: true };
    if (row.hasAttribute("data-highlighted")) highlighted = id;
    const copy = row.cloneNode(true) as Element;
    copy.querySelectorAll('.ui-menu-shortcut,.ui-menu-check,[aria-hidden="true"]').forEach((node) => node.remove());
    const shortcut = row.querySelector(".ui-menu-shortcut")?.textContent?.trim();
    return {
      id,
      label: (copy.textContent ?? "").replace(/\s+/g, " ").trim(),
      ...(shortcut ? { shortcut } : {}),
      checked: row.getAttribute("aria-checked") === "true" || row.getAttribute("aria-selected") === "true",
      disabled: row.getAttribute("aria-disabled") === "true" || row.hasAttribute("data-disabled"),
    };
  });
  return { items, rows, highlighted };
}

/** Whether the menu fits above or below `anchor` in the page (its natural height, every row). */
export function fitsInPage(anchor: DOMRect, height: number, gap: number, viewportHeight: number): boolean {
  const below = viewportHeight - anchor.bottom - gap - EDGE;
  const above = anchor.top - gap - EDGE;
  return height <= Math.max(below, above);
}

/**
 * While `popup` is open: when it has no room in the page and is a flat list of rows (no submenu,
 * no field), shows it through `host` past the window's edge instead.
 */
export function useEscapingMenu(
  host: PopupHost | null,
  element: HTMLElement | null,
  anchor: () => Element | null,
  { side, align, gap }: { side: "bottom" | "top"; align: "start" | "end"; gap: number },
) {
  const anchorRef = useRef(anchor);
  anchorRef.current = anchor;
  useEffect(() => {
    if (!host || !element) return;
    let escaped = false;
    let observer: MutationObserver | undefined;
    let stopListening: (() => void) | undefined;
    const model = (): PopupModel | null => {
      const at = anchorRef.current();
      if (!at) return null;
      const { items, highlighted } = popupItems(element);
      const box = at.getBoundingClientRect();
      return {
        items,
        highlighted,
        anchor: { left: box.left, top: box.top, right: box.right, bottom: box.bottom },
        side,
        align,
        width: element.getBoundingClientRect().width,
      };
    };
    // After Base UI placed the menu (one frame), measure every row against the room.
    const frame = requestAnimationFrame(() => {
      const at = anchorRef.current();
      const flat = !element.querySelector("[aria-haspopup], input, textarea, [contenteditable]");
      const { items } = popupItems(element);
      const natural = element.scrollHeight + (element.offsetHeight - element.clientHeight);
      if (!at || !flat || items.length === 0 || fitsInPage(at.getBoundingClientRect(), natural, gap, innerHeight))
        return;
      const first = model();
      if (!first) return;
      escaped = true;
      // Invisible, not hidden: the page's menu keeps focus and its rows for the keyboard.
      const positioner = element.parentElement;
      positioner?.setAttribute("data-escaped", "");
      positioner?.style.setProperty("opacity", "0");
      positioner?.style.setProperty("pointer-events", "none");
      void host.show(first);
      observer = new MutationObserver(() => {
        const next = model();
        if (next) host.update(next);
      });
      observer.observe(element, {
        subtree: true,
        childList: true,
        characterData: true,
        attributes: true,
        attributeFilter: ["data-highlighted", "aria-checked", "aria-selected", "aria-disabled", "data-disabled"],
      });
      stopListening = host.listen((event) => {
        if (event.type === "pick") (popupItems(element).rows[Number(event.id)] as HTMLElement | undefined)?.click();
        else if (event.type === "dismiss")
          element.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
      });
    });
    return () => {
      cancelAnimationFrame(frame);
      observer?.disconnect();
      stopListening?.();
      if (escaped) {
        const positioner = element.parentElement;
        positioner?.removeAttribute("data-escaped");
        positioner?.style.removeProperty("opacity");
        positioner?.style.removeProperty("pointer-events");
        host.hide();
      }
    };
  }, [host, element, side, align, gap]);
}
