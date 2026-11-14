import {
  cloneElement,
  isValidElement,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ComponentProps,
  type KeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  type ReactElement,
  type ReactNode,
} from "react";
import { createPortal } from "react-dom";
import { Menu as BaseMenu } from "@base-ui/react/menu";
import { cx } from "./cx";
import { MenuCheckGlyph } from "./MenuCheckGlyph";
import { useScrollEdges } from "./scrollEdges";
import { hasNativeMenuPick, nativeMenu, pickedId, type NativeMenuRow } from "./nativeMenu";
import { useEscapingPopup, type AnchorBox } from "./popupHost";
import { useOverlayPosition, usePopupHost } from "./UiProvider";
import { usePopupPadding } from "./popupInset";
import { useNativePopup, type NativePopupDescription } from "./nativePopup";
import type { NativePopupEvent } from "./popupProtocol";
import { popupAction } from "./popupDescriptors";

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
  /**
   * The one child element is the host itself: it takes the right-click and Shift-F10 handlers and
   * no wrapper is drawn, so the child keeps its place among its siblings (a flex slot's `>` and `+`
   * rules, such as Send before the composer's mic). `className` is unused then.
   */
  asChild?: boolean;
  /** Declarative rows for WebPopupHost; rows are never mounted or scraped when supplied. */
  native?: {
    model: NativePopupDescription;
    onEvent?(event: NativePopupEvent, item?: ContextMenuItem): void;
    onDismiss?(): void;
  };
}

/** A row of the page's menu that the arrows reach. */
const ENABLED_ROW = '[role^="menuitem"]:not(:disabled, [aria-disabled="true"])';

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
 *
 * The page's own menu is a Base UI Menu at the pointer (a virtual anchor), as the reference component
 * kit draws its context menu: focus moves onto the highlighted row, so VoiceOver reads each row as
 * the arrows reach it; Home and End, typeahead, Return and Space work on the rows; Escape and Tab
 * close it and put focus back on the control it opened from; and Floating UI keeps it in the window,
 * flipping up or left at the edge. The backdrop, the gesture rules and the native paths are ours.
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
  asChild,
  native,
}: ContextMenuProps) {
  const [point, setPoint] = useState<{ x: number; y: number } | null>(null);
  const [nativeAnchor, setNativeAnchor] = useState<AnchorBox | null>(null);
  const [nativeOpen, setNativeOpen] = useState(false);
  const returnFocus = useRef<HTMLElement | null>(null);
  // The page menu's first focus moves to its first row (see the popup's onFocus).
  const firstFocus = useRef(false);
  const popupTarget = useRef<HTMLElement | null>(null);
  const nativeRequest = useRef(0);
  const menu = useRef<HTMLDivElement | null>(null);
  const host = usePopupHost();
  const positionMethod = useOverlayPosition();
  const padding = usePopupPadding();
  // The page menu's portal: the backdrop, so the rows sit above it and its handlers see their events.
  const [backdrop, setBackdrop] = useState<HTMLDivElement | null>(null);
  const nativePopup = useNativePopup({
    open: nativeOpen && native !== undefined,
    model: native?.model ?? { side: "bottom", align: "start", width: 0, rows: [] },
    anchor: () => nativeAnchor,
    onEvent: (event) => {
      const action = event.type === "pick" && native ? popupAction(native.model, event.id) : undefined;
      const item = event.id ? items.find((candidate) => candidate.id === event.id) : undefined;
      native?.onEvent?.(event, item);
      if (action && item && !item.disabled) {
        item.onSelect();
      }
      if (action && !action.keepOpen) close();
    },
    onDismiss: (reason) => {
      // The host never drew the rows (an older app, a stand-in bridge): the page draws its own menu
      // where the right-click was, as when the legacy native menu is refused.
      const anchor = reason === "refused" ? nativeAnchor?.getBoundingClientRect() : undefined;
      if (anchor) {
        setNativeOpen(false);
        openPage({ x: anchor.left, y: anchor.top });
        return;
      }
      close();
      native?.onDismiss?.();
    },
  });
  const [shown, setShown] = useState<HTMLDivElement | null>(null);
  const edges = useScrollEdges();
  const attach = useCallback(
    (node: HTMLDivElement | null) => {
      menu.current = node;
      if (host) setShown(node);
    },
    [host],
  );
  useEffect(
    () => () => {
      nativeRequest.current += 1;
      popupTarget.current?.removeAttribute("data-popup-open");
      popupTarget.current = null;
    },
    [],
  );
  // No room above or below the pointer in the page: past the window's edge, as a Mac context menu
  // (popupHost.ts). The backdrop stays, so a click on the page still closes it.
  useEscapingPopup(
    host,
    shown,
    () =>
      point && {
        getBoundingClientRect: () => ({
          left: point.x,
          right: point.x,
          top: point.y,
          bottom: point.y,
        }),
      },
    { side: "bottom", align: "start", gap: 0, shell: "self" },
  );
  // The pointer as a zero-size box: Base UI places the menu down and right of it, flipping up or
  // left where the window has no room.
  const anchor = useMemo(
    () =>
      point && {
        getBoundingClientRect: () => {
          const { x, y } = point;
          return {
            x,
            y,
            left: x,
            right: x,
            top: y,
            bottom: y,
            width: 0,
            height: 0,
            toJSON: () => ({}),
          } as DOMRect;
        },
      },
    [point],
  );
  const openPage = (at: { x: number; y: number }) => {
    firstFocus.current = true;
    setPoint(at);
  };
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
  // Base UI asks to close on Escape and on focus leaving the rows. A row's press runs through `run`,
  // and a press outside lands on the backdrop, which closes the menu itself (and must still see a
  // right-click's contextmenu after its pointerdown), so neither closes here.
  const onMenuOpenChange = (open: boolean, details: { reason: string }) => {
    if (open || details.reason === "item-press" || details.reason === "outside-press") return;
    close(true);
  };
  // The host has no role of its own: it relays Shift-F10 from the focusable control inside it.
  const hostKeyDown = (event: KeyboardEvent<Element>) => {
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
  };
  const hostContextMenu = (event: ReactMouseEvent<Element>) => {
    // A menu inside this host already took the right-click (its own item's Hide, inside a
    // row's Show); a host with no items keeps the default.
    if (event.defaultPrevented || items.length === 0) return;
    if (targets === "own" && !(event.target instanceof Node && event.currentTarget.contains(event.target))) return;
    if (selection !== "menu" && window.getSelection()?.isCollapsed === false) return;
    if (ignore && event.target instanceof Element && event.target.closest(ignore)) return;
    const target = event.target instanceof Element ? event.target : null;
    // Find the invoking HTML surface even when the pointer is over a nested SVG. The
    // popup itself anchors at the pointer, preserving the context-menu gesture.
    let nativeAnchor = target;
    while (nativeAnchor && !(nativeAnchor instanceof HTMLElement)) nativeAnchor = nativeAnchor.parentElement;
    const nativeTarget = nativeAnchor instanceof HTMLElement ? nativeAnchor : null;
    if (native && nativePopup.available && !nativeTarget) return;
    event.preventDefault();
    onOpen?.();
    popupTarget.current?.removeAttribute("data-popup-open");
    popupTarget.current = null;
    setPoint(null);
    const requestId = nativeRequest.current + 1;
    nativeRequest.current = requestId;
    setNativeOpen(true);
    const opener = target?.closest<HTMLElement>(RETURN_FOCUS) ?? null;
    popupTarget.current = opener;
    opener?.setAttribute("data-popup-open", "");
    returnFocus.current = opener;
    const at = { x: event.clientX, y: event.clientY };
    if (native && nativePopup.available) {
      setNativeAnchor({
        getBoundingClientRect: () => ({ left: at.x, right: at.x, top: at.y, bottom: at.y }),
      });
      setNativeOpen(true);
      return;
    }
    const legacyMenu = nativeMenu();
    const rows = legacyMenu && nativeRows(items);
    if (!legacyMenu || !rows) {
      setNativeOpen(false);
      openPage(at);
      return;
    }
    // The rows as they were at the right-click: the menu runs the one chosen from them.
    const shown = items;
    legacyMenu({ items: rows, point: at }).then(
      (reply) => {
        if (nativeRequest.current !== requestId) return;
        // An older legacy bridge can acknowledge an unknown method with a successful null
        // value. That is not a native-menu dismissal (`{ picked: null }`); fall back to the
        // page menu so a right-click never disappears without an actionable surface.
        if (!hasNativeMenuPick(reply)) {
          setNativeOpen(false);
          openPage(at);
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
        openPage(at);
      },
    );
  };
  const rest = (
    <>
      <span aria-hidden="true" hidden data-popup-open={point || nativeOpen ? "" : undefined} />
      {point
        ? createPortal(
            // Placement is inline, not only in ui.css: a host that does not load ui.css (the agent
            // pane) still opens the menu at the pointer above the page (cx-j4sd).
            <div
              ref={setBackdrop}
              className="ui-context-menu-backdrop"
              style={{ position: "fixed", inset: 0, zIndex: "var(--layer-dropdown)" }}
              // A right-click (or Control-click) comes as pointerdown then contextmenu: closing on its
              // pointerdown would take the backdrop away before contextmenu, and the browser's menu
              // would open. Every other press (a click, a middle click) has no contextmenu after it.
              onPointerDown={(event) => {
                if (event.button !== 2 && !(event.button === 0 && event.ctrlKey)) close(true);
              }}
              // A right-click on the open menu or its backdrop stays here: the browser's own menu
              // would open over it, and under `asChild` no host above the portal takes the event.
              // On the backdrop it closes the menu, as a click there does.
              onContextMenu={(event) => {
                event.preventDefault();
                event.stopPropagation();
                if (event.target === event.currentTarget) close(true);
              }}
            >
              {backdrop ? (
                <BaseMenu.Root open modal={false} onOpenChange={onMenuOpenChange}>
                  <BaseMenu.Portal container={backdrop}>
                    <BaseMenu.Positioner
                      className="ui-positioner ui-context-menu-positioner"
                      positionMethod={positionMethod}
                      anchor={anchor}
                      side="bottom"
                      align="start"
                      sideOffset={0}
                      collisionPadding={padding}
                      // Inline, not only in ui.css: a host without ui.css (the agent pane) keeps it fixed.
                      style={{ position: "fixed" }}
                    >
                      <BaseMenu.Popup
                        ref={attach}
                        className={cx("ui-popup ui-glass ui-context-menu ui-popup-scroll-shell", popupClassName)}
                        // The App's menu glass under the page, as ui/Menu's popups (ui/glass/hostGlass.ts).
                        data-host-glass="menu"
                        data-host-glass-cover=""
                        data-focus-ring="rows"
                        style={{ minWidth: 180 }}
                        // Focus goes back to the opener here (`close`), not where Base UI would put it.
                        finalFocus={false}
                        onPointerDown={(event) => event.stopPropagation()}
                        // The menu opens with its first enabled row highlighted and focused, as the page's
                        // menu always did, so VoiceOver reads a row and Return runs it. Base UI focuses the
                        // popup itself on open; that first focus moves on to the row.
                        onFocus={(event) => {
                          if (event.target !== event.currentTarget || !firstFocus.current) return;
                          firstFocus.current = false;
                          event.currentTarget.querySelector<HTMLElement>(ENABLED_ROW)?.focus({ preventScroll: true });
                        }}
                        onKeyDown={(event) => {
                          // A menu has no Tab order of its own (a macOS menu ignores Tab): Tab closes it
                          // and hands focus back, never moving it apart from the highlighted row.
                          if (event.key === "Tab") {
                            event.preventDefault();
                            close(true);
                            return;
                          }
                          // Return or Space with the menu itself focused (its first row has not taken
                          // focus yet) runs the highlighted row, else the first enabled one, as the row would.
                          if ((event.key === "Enter" || event.key === " ") && event.target === event.currentTarget) {
                            const row =
                              event.currentTarget.querySelector<HTMLElement>(`${ENABLED_ROW}[data-highlighted]`) ??
                              event.currentTarget.querySelector<HTMLElement>(ENABLED_ROW);
                            if (!row) return;
                            event.preventDefault();
                            row.click();
                          }
                        }}
                      >
                        <div ref={edges} className="ui-popup-scroll ui-scroll-edge-fade">
                          {items.map((item) => (
                            <div key={item.id} role="none">
                              {item.separatorBefore ? <hr className="ui-separator" /> : null}
                              <ContextMenuRow item={item} run={run} />
                            </div>
                          ))}
                        </div>
                      </BaseMenu.Popup>
                    </BaseMenu.Positioner>
                  </BaseMenu.Portal>
                </BaseMenu.Root>
              ) : null}
            </div>,
            document.body,
          )
        : null}
    </>
  );
  if (asChild && isValidElement(children)) {
    const child = children as ReactElement<{
      onKeyDown?(event: KeyboardEvent<Element>): void;
      onContextMenu?(event: ReactMouseEvent<Element>): void;
    }>;
    return (
      <>
        {/* Before the child, so the child's next sibling stays its own. */}
        {rest}
        {cloneElement(child, {
          onKeyDown: (event: KeyboardEvent<Element>) => {
            child.props.onKeyDown?.(event);
            hostKeyDown(event);
          },
          onContextMenu: (event: ReactMouseEvent<Element>) => {
            child.props.onContextMenu?.(event);
            hostContextMenu(event);
          },
        })}
      </>
    );
  }
  return (
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions
    <div className={cx("ui-context-menu-host", className)} onKeyDown={hostKeyDown} onContextMenu={hostContextMenu}>
      {children}
      {rest}
    </div>
  );
}

/** A row's element: a button, as the page's rows always were (the pane's menu styles read them). */
const rowButton = (props: ComponentProps<"button">) => <button type="button" {...props} />;

/** One row of the page's menu: a Base UI item (a checkbox item for a toggle) drawn on the menu grid. */
function ContextMenuRow({ item, run }: { item: ContextMenuItem; run(item: ContextMenuItem): void }) {
  const className = cx("ui-menu-item", item.destructive && "ui-menu-item-destructive");
  const label = item.ariaLabel ?? (typeof item.label === "string" ? item.label : undefined);
  const content = (
    <>
      {/* A toggle's check sits on the menu's state column and an icon in the 14 box at the leading
          (popupSurface.css, "EVERY MENU ON ONE GRID"), so checked, unchecked and plain rows start
          their text on one line. */}
      {item.checked !== undefined ? (
        <span className="ui-menu-check" aria-hidden="true">
          {item.checked ? <MenuCheckGlyph /> : null}
        </span>
      ) : null}
      {item.icon ? (
        <span className="ui-menu-icon" aria-hidden="true">
          {item.icon}
        </span>
      ) : null}
      {/* A text label truncates; a composed label (text plus a shortcut) keeps its own flex layout. */}
      {typeof item.label === "string" ? <span className="ui-menu-label">{item.label}</span> : item.label}
    </>
  );
  // A disabled row stays out of Base UI's list, so the arrows, Home, End and typeahead skip it, as
  // they skip a disabled item of a macOS menu; it is still read as a dimmed, unavailable row.
  if (item.disabled)
    return (
      <button
        type="button"
        role={item.checked === undefined ? "menuitem" : "menuitemcheckbox"}
        aria-checked={item.checked}
        className={className}
        disabled
        aria-disabled="true"
        aria-label={label}
        tabIndex={-1}
      >
        {content}
      </button>
    );
  // Typeahead matches the row's text: a composed label's comes from its accessible name.
  if (item.checked !== undefined)
    return (
      <BaseMenu.CheckboxItem
        className={className}
        checked={item.checked}
        disabled={item.disabled}
        aria-label={label}
        label={label}
        closeOnClick
        nativeButton
        render={rowButton}
        onClick={(event) => {
          // The row runs here and the menu closes itself (`run`): Base UI's own click handler would
          // focus the row again after the action, taking focus back from where the action put it.
          event.preventBaseUIHandler();
          run(item);
        }}
      >
        {content}
      </BaseMenu.CheckboxItem>
    );
  return (
    <BaseMenu.Item
      className={className}
      disabled={item.disabled}
      aria-label={label}
      label={label}
      nativeButton
      render={rowButton}
      onClick={(event) => {
        event.preventBaseUIHandler();
        run(item);
      }}
    >
      {content}
    </BaseMenu.Item>
  );
}
