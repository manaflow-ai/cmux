import { useCallback, useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { cx } from "./cx";
import { nativeMenu, pickedId, type NativeMenuRow } from "./nativeMenu";
import { useEscapingPopup } from "./popupHost";
import { usePopupHost } from "./UiProvider";

/** An action in the standalone context menu. */
export interface ContextMenuItem {
  id: string;
  label: ReactNode;
  /** An icon before the label, as macOS shows on items such as Hide (HideableChrome.tsx). */
  icon?: ReactNode;
  /** The icon in the app's native menu: an SF Symbol or an icon pack name (nativeMenu.ts). */
  symbol?: string;
  ariaLabel?: string;
  disabled?: boolean;
  /** A toggle action; false still renders as a checkbox menu item. */
  checked?: boolean;
  destructive?: boolean;
  separatorBefore?: boolean;
  onSelect(): void;
}

export interface ContextMenuProps {
  items: readonly ContextMenuItem[];
  children: ReactNode;
  className?: string;
  popupClassName?: string;
  /**
   * "menu": a right-click over selected text opens this menu too (the surface offers its own
   * selected-text items, such as Cut and Copy). By default a selection keeps the host's menu.
   */
  selection?: "menu";
  /** Called as the menu opens, before it renders, so items can read what was under the pointer. */
  onOpen?(): void;
  /** Targets (a CSS selector) that keep the host's own menu, such as a text field's Cut, Copy and Paste. */
  ignore?: string;
  /**
   * "own": only a right-click on this host's own DOM opens the menu. React passes events up from a
   * popup a child opened (a picker's search field), though the popup draws elsewhere on the page.
   */
  targets?: "own";
}

/** The control a closed menu gives focus back to. */
const RETURN_FOCUS =
  "button, a[href], input, select, textarea, [contenteditable]:not([contenteditable='false']), [role='textbox'], [tabindex]:not([tabindex='-1'])";

/**
 * The rows the app's native menu shows, or null when a row has no text to show (a composed label
 * with no `ariaLabel`): the page then draws the menu.
 */
function nativeRows(items: readonly ContextMenuItem[]): NativeMenuRow[] | null {
  const rows: NativeMenuRow[] = [];
  for (const item of items) {
    const label = typeof item.label === "string" ? item.label : item.ariaLabel;
    if (!label) return null;
    if (item.separatorBefore) rows.push({ id: `separator:${item.id}`, label: "", separator: true });
    rows.push({
      id: item.id,
      label,
      ...(item.symbol ? { symbol: item.symbol } : {}),
      ...(item.disabled ? { disabled: true } : {}),
      ...(item.checked !== undefined ? { checked: item.checked } : {}),
    });
  }
  return rows;
}

/** Inline, as the placement is: the agent pane does not load ui.css. */
const MENU_ICON = {
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "center",
  width: 16,
  height: 16,
  flex: "none",
} as const;

/**
 * A point-anchored context menu for surfaces that do not use the shared Menu trigger.
 * It owns only the context-menu gesture; regular menus and selects should use `Menu`/`Select`.
 * A right-click over selected text keeps the host's native menu (Copy), unless `selection="menu"`.
 * The menu renders at the document root: a fixed popup inside an ancestor with a transform (or a
 * transform animation, such as a settings category's enter animation) is placed relative to that
 * ancestor, not the viewport, so it opened away from the pointer (cx-dmnf). Closing attempts to
 * restore the invoking control when it remains connected at the close turn; navigation actions
 * own any later focus changes. Like a native menu, it opens down and right of the pointer and
 * flips up or left where that would leave the window. The keyboard opens it too: Shift-F10 or the
 * context-menu key on a focused control inside the host opens it at that control's bottom start
 * corner, so every surface with a right-click menu has a keyboard path. In the app the menu is a
 * standard macOS menu the host draws (nativeMenu.ts); the page draws its own only without a host,
 * or when the host refuses.
 */
export function ContextMenu({
  items,
  children,
  className,
  popupClassName,
  selection,
  onOpen,
  ignore,
  targets,
}: ContextMenuProps) {
  const [point, setPoint] = useState<{ x: number; y: number } | null>(null);
  const [nativeOpen, setNativeOpen] = useState(false);
  const [active, setActive] = useState(0);
  const returnFocus = useRef<HTMLElement | null>(null);
  const popupTarget = useRef<HTMLElement | null>(null);
  const nativeRequest = useRef(0);
  const menu = useRef<HTMLDivElement | null>(null);
  const host = usePopupHost();
  const [shown, setShown] = useState<HTMLDivElement | null>(null);
  const attach = useCallback(
    (node: HTMLDivElement | null) => {
      menu.current = node;
      if (host) setShown(node);
    },
    [host],
  );
  useEffect(() => () => {
    nativeRequest.current += 1;
    popupTarget.current?.removeAttribute("data-popup-open");
    popupTarget.current = null;
  }, []);
  // No room above or below the pointer in the page: past the window's edge, as a Mac context menu
  // (popupHost.ts). The backdrop stays, so a click on the page still closes it.
  useEscapingPopup(
    host,
    shown,
    () => point && { getBoundingClientRect: () => ({ left: point.x, right: point.x, top: point.y, bottom: point.y }) },
    { side: "bottom", align: "start", gap: 0, shell: "self" },
  );
  // Where the menu sits, measured before it paints.
  const [place, setPlace] = useState<{ left: number; top: number } | null>(null);
  useLayoutEffect(() => {
    const node = menu.current;
    if (!point || !node) {
      setPlace(null);
      return;
    }
    const { width, height } = node.getBoundingClientRect();
    const left = point.x + width > window.innerWidth - 4 ? point.x - width : point.x;
    const top = point.y + height > window.innerHeight - 4 ? point.y - height : point.y;
    setPlace({
      left: Math.max(4, Math.min(left, window.innerWidth - width - 4)),
      top: Math.max(4, Math.min(top, window.innerHeight - height - 4)),
    });
  }, [point]);
  // Takes focus once placed (a hidden menu cannot take it), so Up/Down/Return work.
  useLayoutEffect(() => {
    if (place) menu.current?.focus();
  }, [place]);
  const enabled = items.filter((item) => !item.disabled);
  const close = (restoreFocus = false) => {
    nativeRequest.current += 1;
    setPoint(null);
    setNativeOpen(false);
    popupTarget.current?.removeAttribute("data-popup-open");
    popupTarget.current = null;
    const target = returnFocus.current;
    returnFocus.current = null;
    if (restoreFocus && target?.isConnected) target.focus({ preventScroll: true });
  };
  const run = (item: ContextMenuItem | undefined) => {
    if (!item || item.disabled) return;
    // Keep the opener across the action. The action may remove or replace it (for example, a
    // sidebar row's Close action), so restoring before `onSelect` would focus a node that is about
    // to disappear. Restore only when the action did not deliberately move focus elsewhere.
    const target = returnFocus.current;
    close();
    item.onSelect();
    queueMicrotask(() => {
      if (!target?.isConnected) return;
      const focused = document.activeElement;
      if (focused && focused !== document.body && focused !== document.documentElement) return;
      target.focus({ preventScroll: true });
    });
  };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>, restoreFocus = false) => {
    if (event.key === "Escape") {
      event.preventDefault();
      close(restoreFocus);
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (enabled.length === 0) return;
      event.preventDefault();
      setActive((index) => (index + (event.key === "ArrowDown" ? 1 : -1) + enabled.length) % enabled.length);
    } else if (event.key === "Home" || event.key === "End") {
      if (enabled.length === 0) return;
      event.preventDefault();
      setActive(event.key === "Home" ? 0 : enabled.length - 1);
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      run(enabled[active]);
    }
  };
  return (
    // The host has no role of its own: it relays Shift-F10 from the focusable control inside it.
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions
    <div
      className={cx("ui-context-menu-host", className)}
      onKeyDown={(event) => {
        if (event.defaultPrevented || items.length === 0) return;
        if (!(event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey))) return;
        const target = event.target instanceof Element ? event.target : null;
        // A key in the open menu (a portal, so React passes it up here) is the menu's own.
        if (!target || menu.current?.contains(target)) return;
        event.preventDefault();
        // The same path as a right-click at the control's bottom start corner: a host that learns
        // the menu's subject from its own contextmenu capture handler sees this open too, and the
        // selection, `ignore` and `targets` rules apply alike.
        const rect = target.getBoundingClientRect();
        const rtl = getComputedStyle(target).direction === "rtl";
        target.dispatchEvent(
          new MouseEvent("contextmenu", {
            bubbles: true,
            cancelable: true,
            clientX: rtl ? rect.right : rect.left,
            clientY: rect.bottom,
          }),
        );
      }}
      onContextMenu={(event) => {
        // A menu inside this host already took the right-click (its own item's Hide, inside a
        // row's Show); a host with no items keeps the default.
        if (event.defaultPrevented || items.length === 0) return;
        if (targets === "own" && !(event.target instanceof Node && event.currentTarget.contains(event.target))) return;
        if (selection !== "menu" && window.getSelection()?.isCollapsed === false) return;
        if (ignore && event.target instanceof Element && event.target.closest(ignore)) return;
        event.preventDefault();
        onOpen?.();
        popupTarget.current?.removeAttribute("data-popup-open");
        popupTarget.current = null;
        setPoint(null);
        const requestId = nativeRequest.current + 1;
        nativeRequest.current = requestId;
        setNativeOpen(true);
        setActive(0);
        const target = event.target instanceof Element ? event.target : null;
        const opener = target?.closest<HTMLElement>(RETURN_FOCUS) ?? null;
        popupTarget.current = opener;
        opener?.setAttribute("data-popup-open", "");
        returnFocus.current = opener;
        const at = { x: event.clientX, y: event.clientY };
        const native = nativeMenu();
        const rows = native && nativeRows(items);
        if (!native || !rows) {
          setNativeOpen(false);
          setPoint(at);
          return;
        }
        // The rows as they were at the right-click: the menu runs the one chosen from them.
        const shown = items;
        native({ items: rows, point: at }).then(
          (reply) => {
            if (nativeRequest.current !== requestId) return;
            // An older legacy bridge can acknowledge an unknown method with a successful null
            // value. That is not a native-menu dismissal (`{ picked: null }`); fall back to the
            // page menu so a right-click never disappears without an actionable surface.
            if (!reply || typeof reply !== "object" || !("picked" in reply)) {
              setNativeOpen(false);
              setPoint(at);
              return;
            }
            const chosen = shown.find((item) => item.id === pickedId(reply));
            if (chosen) run(chosen);
            else close(true);
          },
          // A host without the native menu (an older app): the page draws it.
          () => {
            if (nativeRequest.current !== requestId) return;
            setNativeOpen(false);
            setPoint(at);
          },
        );
      }}
    >
      {children}
      <span aria-hidden="true" hidden data-popup-open={point || nativeOpen ? "" : undefined} />
      {point
        ? createPortal(
            // Placement is inline, not only in ui.css: a host that does not load ui.css (the agent
            // pane) still opens the menu at the pointer above the page (cx-j4sd).
            <div
              className="ui-context-menu-backdrop"
              style={{ position: "fixed", inset: 0, zIndex: "var(--layer-dropdown)" }}
              onPointerDown={() => close(true)}
            >
              <div
                ref={attach}
                className={cx("ui-popup ui-glass ui-context-menu", popupClassName)}
                role="menu"
                data-focus-ring="rows"
                tabIndex={-1}
                style={{
                  position: "fixed",
                  minWidth: 180,
                  left: place?.left ?? point.x,
                  top: place?.top ?? point.y,
                  visibility: place ? undefined : "hidden",
                }}
                onPointerDown={(event) => event.stopPropagation()}
                onKeyDown={(event) => {
                  if (event.key === "Escape") {
                    onKeyDown(event, true);
                    return;
                  }
                  onKeyDown(event);
                }}
              >
                {items.map((item) => (
                  <div key={item.id} role="none">
                    {item.separatorBefore ? <hr className="ui-separator" /> : null}
                    <button
                      type="button"
                      role={item.checked === undefined ? "menuitem" : "menuitemcheckbox"}
                      aria-checked={item.checked}
                      className={cx("ui-menu-item", item.destructive && "ui-menu-item-destructive")}
                      disabled={item.disabled}
                      aria-label={item.ariaLabel ?? (typeof item.label === "string" ? item.label : undefined)}
                      onPointerEnter={() => !item.disabled && setActive(Math.max(0, enabled.indexOf(item)))}
                      data-highlighted={enabled[active] === item ? "" : undefined}
                      onClick={() => run(item)}
                    >
                      {/* A text label truncates with its full text as a tooltip; a composed label
                          (text plus a shortcut) keeps its own flex layout. */}
                      {item.checked !== undefined ? (
                        <span className="ui-menu-icon" aria-hidden="true" style={MENU_ICON}>
                          {item.checked ? "✓" : null}
                        </span>
                      ) : item.icon ? (
                        <span className="ui-menu-icon" aria-hidden="true" style={MENU_ICON}>
                          {item.icon}
                        </span>
                      ) : null}
                      {typeof item.label === "string" ? (
                        <span className="ui-menu-label">{item.label}</span>
                      ) : (
                        item.label
                      )}
                    </button>
                  </div>
                ))}
              </div>
            </div>,
            document.body,
          )
        : null}
    </div>
  );
}
