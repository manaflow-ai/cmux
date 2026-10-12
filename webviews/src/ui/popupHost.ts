// A small transient surface with no room in the page goes past the window's edge (cx-6k6cg), as a
// Mac menu does: menus, the composer's slash and @ lists, tooltips. Base UI flips a menu to the
// side that fits; when neither side of its anchor has room for every row (a list fixed on one side:
// that side), the page hands the rows to the native host (WebPopupHost), which draws them in a
// child panel on the screen. The page's own surface stays mounted, invisible: focus, the arrows,
// typeahead and accessibility stay the page's. Its highlight and rows follow to the host as they
// change; a click there comes back as the page row's own click (a menu) or mouse-down (a list that
// keeps the focus in its field). Pages without a host (Settings) never escape: their menus fit and
// scroll in the page.
import { useEffect, useRef, useState } from "react";
import { usePopupHost } from "./UiProvider";

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
  kind?: PopupKind;
}

/**
 * - `menu`: Base UI menu rows (`data-highlighted`), picked by a click;
 * - `list`: a listbox whose field keeps the focus (`aria-activedescendant`): `aria-selected` is the
 *   highlight, a row picks on mouse-down and highlights on pointer move;
 * - `tooltip`: its text as one row that takes no clicks.
 */
export type PopupKind = "menu" | "list" | "tooltip";

/** What a menu opened from: an element or a virtual anchor. */
export type AnchorBox = { getBoundingClientRect(): { left: number; top: number; right: number; bottom: number } };

export type PopupEvent = { type: "pick"; id: string } | { type: "highlight"; id: string } | { type: "dismiss" };

export interface PopupHost {
  /** Resolves `{shown: true}` once the rows show; anything else leaves the menu in the page. */
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

/** The surface's rows as the host draws them: each row's text without its check or shortcut. */
export function popupItems(
  popup: Element,
  kind: PopupKind = "menu",
): { items: PopupItem[]; rows: Element[]; highlighted: string | null } {
  if (kind === "tooltip") {
    const copy = popup.cloneNode(true) as Element;
    copy.querySelectorAll(".ui-tooltip-hint").forEach((node) => node.remove());
    const shortcut = popup.querySelector(".ui-tooltip-hint")?.textContent?.trim();
    const label = (copy.textContent ?? "").replace(/\s+/g, " ").trim();
    return {
      items: label ? [{ id: "0", label, ...(shortcut ? { shortcut } : {}) }] : [],
      rows: [popup],
      highlighted: null,
    };
  }
  const rows = [...popup.querySelectorAll(kind === "list" ? '[role="option"]' : ROWS)];
  let highlighted: string | null = null;
  const items = rows.map((row, index): PopupItem => {
    const id = String(index);
    if (row.getAttribute("role") === "separator") return { id, label: "", separator: true };
    const selected = row.getAttribute("aria-selected") === "true";
    if (kind === "list" ? selected : row.hasAttribute("data-highlighted")) highlighted = id;
    const copy = row.cloneNode(true) as Element;
    copy.querySelectorAll('.ui-menu-shortcut,.ui-menu-check,[aria-hidden="true"]').forEach((node) => node.remove());
    const shortcut = row.querySelector(".ui-menu-shortcut")?.textContent?.trim();
    return {
      id,
      label: (copy.textContent ?? "").replace(/\s+/g, " ").trim(),
      ...(shortcut ? { shortcut } : {}),
      checked: row.getAttribute("aria-checked") === "true" || (kind === "menu" && selected),
      disabled: row.getAttribute("aria-disabled") === "true" || row.hasAttribute("data-disabled"),
    };
  });
  return { items, rows, highlighted };
}

/**
 * The surface's height with every list in it at its designed size: a list that scrolls (the
 * surface itself or one inside it) counts its hidden rows too, up to its `--popup-scroll-cap` when
 * it sets one (a list that scrolls by design at that size, as the folder menu's and the slash
 * menu's). A small window that squeezes a list below its cap does not make the surface fit.
 */
export function naturalHeight(popup: HTMLElement): number {
  let hidden = 0;
  for (const list of [popup, ...popup.querySelectorAll<HTMLElement>("*")]) {
    if (list.scrollHeight <= list.clientHeight + 1) continue;
    const style = getComputedStyle(list);
    if (!/auto|scroll/.test(style.overflowY)) continue;
    const cap = parseFloat(style.getPropertyValue("--popup-scroll-cap"));
    const designed = Number.isFinite(cap) ? Math.min(list.scrollHeight, cap) : list.scrollHeight;
    hidden += Math.max(0, designed - list.clientHeight);
  }
  return popup.offsetHeight + hidden;
}

/**
 * Whether the surface fits above or below `anchor` in the page (its natural height, every row);
 * with `only`, on that side alone (a list fixed above its field).
 */
export function fitsInPage(
  anchor: { top: number; bottom: number },
  height: number,
  gap: number,
  viewportHeight: number,
  only?: "top" | "bottom",
): boolean {
  const below = viewportHeight - anchor.bottom - gap - EDGE;
  const above = anchor.top - gap - EDGE;
  return height <= (only === "top" ? above : only === "bottom" ? below : Math.max(below, above));
}

export interface EscapeOptions {
  side: "bottom" | "top";
  align: "start" | "end";
  gap: number;
  kind?: PopupKind;
  /** False for a surface the page keeps on `side` (no flip): only that side's room counts. */
  flip?: boolean;
}

/**
 * While `popup` is open: when it has no room in the page (and, a menu, is a flat list of rows: no
 * submenu, no field), shows it through `host` past the window's edge instead.
 */
export function useEscapingPopup(
  host: PopupHost | null,
  element: HTMLElement | null,
  anchor: () => AnchorBox | null,
  { side, align, gap, kind = "menu", flip = true }: EscapeOptions,
) {
  const anchorRef = useRef(anchor);
  anchorRef.current = anchor;
  useEffect(() => {
    if (!host || !element) return;
    let escaped = false;
    let alive = true;
    let observer: MutationObserver | undefined;
    let stopListening: (() => void) | undefined;
    // A Base UI surface hides by its positioner; a list positioned by its own CSS, by itself.
    const shell = kind === "list" ? element : element.parentElement;
    const model = (): PopupModel | null => {
      const at = anchorRef.current();
      if (!at) return null;
      const { items, highlighted } = popupItems(element, kind);
      const box = at.getBoundingClientRect();
      return {
        items,
        highlighted,
        anchor: { left: box.left, top: box.top, right: box.right, bottom: box.bottom },
        side,
        align,
        width: kind === "tooltip" ? element.scrollWidth + 2 : element.getBoundingClientRect().width,
        kind,
      };
    };
    const row = (id: string) => popupItems(element, kind).rows[Number(id)] as HTMLElement | undefined;
    const restore = () => {
      observer?.disconnect();
      stopListening?.();
      if (!escaped) return;
      escaped = false;
      shell?.removeAttribute("data-escaped");
      shell?.style.removeProperty("opacity");
      shell?.style.removeProperty("pointer-events");
      host.hide();
    };
    // After the page placed the surface (one frame), measure every row against the room.
    const frame = requestAnimationFrame(() => {
      const at = anchorRef.current();
      const flat = kind !== "menu" || !element.querySelector("[aria-haspopup], input, textarea, [contenteditable]");
      const { items } = popupItems(element, kind);
      const room = at?.getBoundingClientRect();
      const fits =
        !room ||
        (fitsInPage(room, naturalHeight(element), gap, innerHeight, flip ? undefined : side) &&
          (kind !== "tooltip" || element.scrollWidth <= innerWidth - 2 * EDGE));
      if (!flat || items.length === 0 || fits) return;
      const first = model();
      if (!first) return;
      escaped = true;
      // Invisible, not hidden: the page's surface keeps focus and its rows for the keyboard.
      shell?.setAttribute("data-escaped", "");
      shell?.style.setProperty("opacity", "0");
      shell?.style.setProperty("pointer-events", "none");
      // The host could not show it (no screen, a hidden window): the surface stays in the page.
      void host.show(first).then((reply) => {
        if (!alive || (reply as { shown?: boolean } | undefined)?.shown === true) return;
        restore();
      });
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
        if (event.type === "pick") {
          const target = row(event.id);
          if (kind === "list")
            target?.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 }));
          else target?.click();
        } else if (event.type === "highlight") {
          // A hover there moves the page's highlight, so Return picks the row under the pointer.
          const target = row(event.id);
          if (kind === "list") {
            target?.dispatchEvent(new PointerEvent("pointermove", { bubbles: true }));
            target?.dispatchEvent(new MouseEvent("mousemove", { bubbles: true }));
          } else {
            target?.dispatchEvent(new MouseEvent("mousemove", { bubbles: true }));
            target?.focus({ preventScroll: true });
          }
        } else if (kind !== "tooltip") {
          // A list's field takes Escape where the focus is; a menu, itself. A tooltip closes with
          // its pointer leaving, so it sends nothing.
          const to = kind === "menu" ? element : (document.activeElement ?? document.body);
          to.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
        }
      });
    });
    return () => {
      alive = false;
      cancelAnimationFrame(frame);
      restore();
    };
  }, [host, element, side, align, gap, kind, flip]);
}

/**
 * A listbox the page keeps on one side of its field with CSS (the composer's slash and @ lists):
 * the ref for it. With no room on that side, its rows go past the window's edge. Undefined on a
 * page without a host.
 */
export function useEscapingList(side: "top" | "bottom", gap: number): ((list: HTMLElement | null) => void) | undefined {
  const host = usePopupHost();
  const [list, setList] = useState<HTMLElement | null>(null);
  useEscapingPopup(host, list, () => list?.offsetParent ?? null, {
    side,
    align: "start",
    gap,
    kind: "list",
    flip: false,
  });
  return host ? setList : undefined;
}
