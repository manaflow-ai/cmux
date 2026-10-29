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
import type { NativePopupTransport } from "./nativePopup";
import type { NativePopupEvent } from "./generated/popupProtocol";

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

/**
 * One panel per page: the surface that showed it (`owner`) updates and hides it; another surface
 * finds it taken and stays in the page.
 */
export interface PopupHost {
  /** Declarative native rendering. Legacy overflow consumers migrate to this path. */
  native?: NativePopupTransport;
  /** Resolves `{shown: true}` once the rows show; anything else leaves the surface in the page. */
  show(model: PopupModel, owner: object): Promise<unknown>;
  update(model: PopupModel, owner: object): void;
  hide(owner: object): void;
  /** The surface showing the panel, if any. */
  owner(): object | null;
  listen(listener: (event: PopupEvent) => void): () => void;
}

/**
 * A host over the native calls (`post("show" | "update" | "hide", model)`) and the host's events
 * (`listen`, which returns its unsubscribe).
 */
export function createPopupHost(
  post: (call: "show" | "update" | "hide", params: Record<string, unknown>) => Promise<unknown>,
  listen: (listener: (event: PopupEvent) => void) => () => void,
): PopupHost {
  const quiet = (call: "show" | "update" | "hide", params: Record<string, unknown> = {}) =>
    post(call, params).catch(() => undefined);
  // Menus and lists open in one frame, including the rows shown past a chat pane's edge.
  // New Tab also suppresses tooltip entrances; other tooltips keep their own motion.
  const request = (model: PopupModel): Record<string, unknown> =>
    model.kind !== "tooltip" ||
    (typeof document !== "undefined" && document.documentElement.hasAttribute("data-new-tab"))
      ? { ...model, instant: true }
      : { ...model };
  let current: object | null = null;
  return {
    native: {
      show: (model) => quiet("show", { ...model }),
      update: (model) => void quiet("update", { ...model }),
      hide: (id, revision) => void quiet("hide", { schemaVersion: 1, id, revision }),
      listen: (listener) =>
        listen((event) => {
          const native = event as unknown as NativePopupEvent;
          if (typeof native.popupId === "string" && Number.isSafeInteger(native.revision)) listener(native);
        }),
    },
    show(model, owner) {
      current = owner;
      return quiet("show", request(model));
    },
    update(model, owner) {
      if (owner === current) void quiet("update", request(model));
    },
    hide(owner) {
      if (owner !== current) return;
      current = null;
      void quiet("hide");
    },
    owner: () => current,
    listen,
  };
}

/** The agent pane's legacy bridge: `popup.show/update/hide` and the window event `cmux-popup`. */
export function nativePopupHost(
  post: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): PopupHost {
  return createPopupHost(
    (call, params) => post(`popup.${call}`, params),
    (listener) => {
      const receive = (event: Event) => listener((event as CustomEvent<PopupEvent>).detail);
      window.addEventListener("cmux-popup", receive);
      return () => window.removeEventListener("cmux-popup", receive);
    },
  );
}

const ROWS = '[role="menuitem"],[role="menuitemradio"],[role="menuitemcheckbox"],[role="option"],[role="separator"],hr';
/** Room kept from the page's edge, as Base UI's collision padding. */
const EDGE = 5;

/** The surface's rows as the host draws them: each row's text without its check or shortcut. */
export function popupItems(
  popup: Element,
  kind: PopupKind = "menu",
  active?: string,
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
  let focused: string | null = null;
  const items = rows.map((row, index): PopupItem => {
    const id = String(index);
    if (row.getAttribute("role") === "separator" || row.tagName === "HR") return { id, label: "", separator: true };
    const selected = row.getAttribute("aria-selected") === "true";
    // The highlight: a class the surface names (aria-selected is then the value), a list's
    // aria-selected, or a menu's data-highlighted row, else its focused one (a row a hover in the
    // host focused keeps focus while the arrows move data-highlighted).
    const lit = active ? row.matches(active) : kind === "list" ? selected : row.hasAttribute("data-highlighted");
    if (lit) highlighted = id;
    if (kind === "menu" && !active && row === row.ownerDocument.activeElement) focused = id;
    const copy = row.cloneNode(true) as Element;
    copy
      .querySelectorAll('.ui-menu-shortcut,.ui-menu-check,[aria-hidden="true"],[data-popup-skip]')
      .forEach((node) => node.remove());
    const shortcut = row.querySelector(".ui-menu-shortcut")?.textContent?.trim();
    return {
      id,
      label: (copy.textContent ?? "").replace(/\s+/g, " ").trim(),
      ...(shortcut ? { shortcut } : {}),
      checked: row.getAttribute("aria-checked") === "true" || ((kind === "menu" || !!active) && selected),
      disabled:
        row.getAttribute("aria-disabled") === "true" ||
        row.hasAttribute("data-disabled") ||
        row.hasAttribute("disabled"),
    };
  });
  return { items, rows, highlighted: highlighted ?? focused };
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

/** A tooltip's text on one line (its page box wraps at the tooltip's max width). */
function textWidth(tooltip: HTMLElement): number {
  const probe = tooltip.cloneNode(true) as HTMLElement;
  probe.style.cssText +=
    ";position:fixed;left:0;top:0;visibility:hidden;max-width:none;width:max-content;white-space:nowrap";
  document.body.append(probe);
  const width = probe.getBoundingClientRect().width;
  probe.remove();
  // Room for the native row's padding and its own font.
  return Math.ceil(width) + 24;
}

export interface EscapeOptions {
  side: "bottom" | "top";
  /**
   * A tooltip whose lines wrap by design at its own max width (a hover card, `.ui-card`): only its
   * height can leave it no room. Measured as one line, a card with a long line in it (a subagent's
   * shell command) read wider than the pane and went to the native panel, flattened to one row and
   * re-placed on every change of its text (Leo 2026-10-22: "this flashes sometimes").
   */
  wraps?: boolean;
  align: "start" | "end";
  gap: number;
  kind?: PopupKind;
  /** False for a surface the page keeps on `side` (no flip): only that side's room counts. */
  flip?: boolean;
  /**
   * What goes invisible while the rows show past the edge: `parent`, a Base UI positioner (the
   * default for menus and tooltips), or `self`, a surface the page positions itself (the default
   * for lists, and a menu over a backdrop that must still take the click that closes it).
   */
  shell?: "self" | "parent";
  /**
   * The highlighted row, as a selector, when a list marks it otherwise than `aria-selected`
   * (`aria-selected` is then the row's value).
   */
  active?: string;
  /** How a list's row picks: on mouse-down (a list beside a field it keeps focused) or a click. */
  pick?: "mousedown" | "click";
  /**
   * The host closed the rows (another app, a resize, a click elsewhere). By default the surface
   * gets an Escape; a field whose Escape clears its text hides its rows here instead.
   */
  onDismiss?: () => void;
}

/**
 * While `popup` is open: when it has no room in the page (and, a menu, is a flat list of rows: no
 * submenu, no field), shows it through `host` past the window's edge instead.
 */
export function useEscapingPopup(
  host: PopupHost | null,
  element: HTMLElement | null,
  anchor: () => AnchorBox | null,
  {
    side,
    align,
    gap,
    kind = "menu",
    flip = true,
    shell: hide,
    active,
    pick = "mousedown",
    onDismiss,
    wraps = false,
  }: EscapeOptions,
) {
  const anchorRef = useRef(anchor);
  anchorRef.current = anchor;
  const dismissRef = useRef(onDismiss);
  dismissRef.current = onDismiss;
  useEffect(() => {
    if (!host || !element) return;
    const me = {};
    let escaped = false;
    let alive = true;
    let frame = 0;
    let observer: MutationObserver | undefined;
    let stopListening: (() => void) | undefined;
    // A Base UI surface hides by its positioner; a list positioned by its own CSS, by itself.
    const shell = (hide ?? (kind === "list" ? "self" : "parent")) === "self" ? element : element.parentElement;
    const model = (): PopupModel | null => {
      const at = anchorRef.current();
      if (!at) return null;
      const { items, highlighted } = popupItems(element, kind, active);
      const box = at.getBoundingClientRect();
      return {
        items,
        highlighted,
        anchor: { left: box.left, top: box.top, right: box.right, bottom: box.bottom },
        side,
        align,
        width: kind === "tooltip" ? textWidth(element) : element.getBoundingClientRect().width,
        kind,
      };
    };
    const row = (id: string) => popupItems(element, kind, active).rows[Number(id)] as HTMLElement | undefined;
    // A menu whose highlight is its focused row: focus moves follow too.
    const refocus = () => {
      const next = escaped ? model() : null;
      if (next) host.update(next, me);
    };
    const restore = () => {
      element.removeEventListener("focusin", refocus);
      observer?.disconnect();
      stopListening?.();
      if (!escaped) return;
      escaped = false;
      shell?.removeAttribute("data-escaped");
      shell?.style.removeProperty("opacity");
      shell?.style.removeProperty("pointer-events");
      shell?.style.removeProperty("transition");
      host.hide(me);
    };
    // Measure every row against the room, after the page placed the surface (one frame) and
    // again whenever its rows change (a list's results arrive after it opens).
    const measure = () => {
      if (!alive || escaped) return;
      // Another surface shows the panel: this one stays in the page.
      if (host.owner() && host.owner() !== me) return;
      const at = anchorRef.current();
      const flat = kind !== "menu" || !element.querySelector("[aria-haspopup], input, textarea, [contenteditable]");
      const { items } = popupItems(element, kind, active);
      const room = at?.getBoundingClientRect();
      const fits =
        !room ||
        (fitsInPage(room, naturalHeight(element), gap, innerHeight, flip ? undefined : side) &&
          (kind !== "tooltip" || wraps || textWidth(element) <= innerWidth - 2 * EDGE));
      if (!flat || items.length === 0 || fits) return;
      const first = model();
      if (!first) return;
      escaped = true;
      observer?.disconnect();
      // Invisible, not hidden: the page's surface keeps focus and its rows for the keyboard. At
      // once: a popup's close fade (popupSurface.css .ui-popup) would draw it beside the host's panel.
      shell?.setAttribute("data-escaped", "");
      shell?.style.setProperty("transition", "none");
      shell?.style.setProperty("opacity", "0");
      shell?.style.setProperty("pointer-events", "none");
      // The host could not show it (no screen, a hidden window): the surface stays in the page.
      void host.show(first, me).then((reply) => {
        if (!alive || (reply as { shown?: boolean } | undefined)?.shown === true) return;
        restore();
      });
      observer = new MutationObserver(() => {
        const next = model();
        if (next) host.update(next, me);
      });
      observer.observe(element, {
        subtree: true,
        childList: true,
        characterData: true,
        attributes: true,
        attributeFilter: [
          "data-highlighted",
          "aria-checked",
          "aria-selected",
          "aria-disabled",
          "data-disabled",
          "disabled",
          ...(active ? ["class"] : []),
        ],
      });
      element.addEventListener("focusin", refocus);
      stopListening = host.listen((event) => {
        if (event.type === "pick") {
          const target = row(event.id);
          if (kind === "list" && pick === "mousedown")
            target?.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true, button: 0 }));
          else target?.click();
        } else if (event.type === "highlight") {
          // A hover there moves the page's highlight, so Return picks the row under the pointer.
          const target = row(event.id);
          // The page's own hover handlers: Base UI's mouse move, a list's pointer move, a
          // context menu's pointer enter (React's comes from pointerover).
          // A move, not a still pointer: WebKit's Base UI lists ignore a mouse move with no movement.
          const moved = { bubbles: true, movementX: 1, movementY: 1 };
          target?.dispatchEvent(new PointerEvent("pointerover", { bubbles: true }));
          target?.dispatchEvent(new PointerEvent("pointermove", moved));
          target?.dispatchEvent(new MouseEvent("mousemove", moved));
          if (kind === "menu") target?.focus({ preventScroll: true });
        } else if (dismissRef.current) {
          dismissRef.current();
        } else if (kind !== "tooltip") {
          // A list's field takes Escape where the focus is; a menu, itself. A tooltip closes with
          // its pointer leaving, so it sends nothing.
          const to = kind === "menu" ? element : (document.activeElement ?? document.body);
          to.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
        }
      });
    };
    const schedule = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(measure);
    };
    schedule();
    observer = new MutationObserver(schedule);
    observer.observe(element, { subtree: true, childList: true, characterData: true });
    return () => {
      alive = false;
      cancelAnimationFrame(frame);
      restore();
    };
  }, [host, element, side, align, gap, kind, flip, hide, active, pick, wraps]);
}

/**
 * A listbox the page keeps on one side of its field with CSS (the composer's slash and @ lists):
 * the ref for it. With no room on that side, its rows go past the window's edge. Undefined on a
 * page without a host.
 */
export function useEscapingList(
  side: "top" | "bottom",
  gap: number,
  onDismiss?: () => void,
): ((list: HTMLElement | null) => void) | undefined {
  const host = usePopupHost();
  const [list, setList] = useState<HTMLElement | null>(null);
  useEscapingPopup(host, list, () => list?.offsetParent ?? null, {
    side,
    align: "start",
    gap,
    kind: "list",
    flip: false,
    onDismiss,
  });
  return host ? setList : undefined;
}
